// append-layers — append the checkpoint onto the runtime image as TRULY
// UNCOMPRESSED OCI tar layers, then push. The weights are already fp8/fp4, so
// gzip buys nothing on the wire; and a plain tar layer (media type
// application/vnd.oci.image.layer.v1.tar, NO gzip wrapper) means both the upload
// and the client's extraction are pure `tar` — no gzip deflate on push, no
// gzip inflate (and no CRC32 pass) on pull. Fast both ways.
//
// go-containerregistry's tarball.LayerFromFile gzips even when you ask for the
// uncompressed media type, so we implement v1.Layer directly: Compressed() ==
// Uncompressed() == the raw tar file, and Digest() == DiffID() (a layer whose
// blob is uncompressed has the same digest for both).
//
// Layers are tarred to $STAGE in parallel while their sha256 is computed in the
// same pass (io.MultiWriter), then appended and pushed.
//
// Env: RUNTIME_IMG FINAL_IMG VERSION MODEL_DIR LAYERS STAGE INSECURE GHCR_USER GHCR_TOKEN
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/types"
)

// rawTarLayer is a v1.Layer backed by an uncompressed tar file on disk. The blob
// served on the wire IS the tar (no gzip), so digest == diffID.
type rawTarLayer struct {
	path   string
	digest v1.Hash
	size   int64
}

func (l *rawTarLayer) Digest() (v1.Hash, error)             { return l.digest, nil }
func (l *rawTarLayer) DiffID() (v1.Hash, error)             { return l.digest, nil }
func (l *rawTarLayer) Size() (int64, error)                 { return l.size, nil }
func (l *rawTarLayer) MediaType() (types.MediaType, error)  { return types.OCIUncompressedLayer, nil }
func (l *rawTarLayer) Compressed() (io.ReadCloser, error)   { return os.Open(l.path) }
func (l *rawTarLayer) Uncompressed() (io.ReadCloser, error) { return os.Open(l.path) }

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	var auth authn.Authenticator = authn.Anonymous
	if os.Getenv("GHCR_TOKEN") != "" {
		auth = &authn.Basic{Username: os.Getenv("GHCR_USER"), Password: os.Getenv("GHCR_TOKEN")}
	}
	var nameOpts []name.Option
	if os.Getenv("INSECURE") == "1" {
		nameOpts = append(nameOpts, name.Insecure)
	}
	runtimeImg := os.Getenv("RUNTIME_IMG")
	finalImg := os.Getenv("FINAL_IMG")
	version := os.Getenv("VERSION")
	modelDir := env("MODEL_DIR", "/workspace/models/DeepSeek-V4-Flash-0731-abliterated")
	stage := env("STAGE", "/root/stage-tars")
	nLayers, _ := strconv.Atoi(env("LAYERS", "20"))
	if nLayers < 1 {
		nLayers = 20
	}
	if err := os.MkdirAll(stage, 0o755); err != nil {
		log.Fatal(err)
	}

	bref, err := name.ParseReference(runtimeImg, nameOpts...)
	if err != nil {
		log.Fatal(err)
	}
	base, err := remote.Image(bref, remote.WithAuth(auth))
	if err != nil {
		log.Fatalf("read runtime image: %v", err)
	}

	// Model is at <baseDir>/models/<name>; tar with -C <baseDir> so layer paths
	// are models/<name>/... and extract to /models/<name>/... in the image.
	parent := filepath.Dir(modelDir)
	baseDir := filepath.Dir(parent)

	var shards, aux []string
	if err := filepath.Walk(modelDir, func(p string, info os.FileInfo, e error) error {
		if e != nil || info.IsDir() {
			return e
		}
		rel, _ := filepath.Rel(baseDir, p)
		if strings.HasSuffix(p, ".safetensors") {
			shards = append(shards, rel)
		} else {
			aux = append(aux, rel)
		}
		return nil
	}); err != nil {
		log.Fatal(err)
	}
	sort.Strings(shards)

	// groups: one aux layer + nLayers round-robin shard layers
	groups := [][]string{aux}
	sh := make([][]string, nLayers)
	for i, f := range shards {
		sh[i%nLayers] = append(sh[i%nLayers], f)
	}
	for _, g := range sh {
		if len(g) > 0 {
			groups = append(groups, g)
		}
	}

	// tar each group to a file AND hash it in one pass (io.MultiWriter), parallel.
	fmt.Printf("taring %d uncompressed layers to %s (parallel, hashing inline)\n", len(groups), stage)
	layers := make([]v1.Layer, len(groups))
	sem := make(chan struct{}, 6)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error
	for i, g := range groups {
		wg.Add(1)
		go func(i int, g []string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			tp := filepath.Join(stage, fmt.Sprintf("layer-%03d.tar", i))
			f, err := os.Create(tp)
			if err != nil {
				mu.Lock(); if firstErr == nil { firstErr = err }; mu.Unlock(); return
			}
			h := sha256.New()
			cmd := exec.Command("tar", append([]string{"cf", "-", "-C", baseDir}, g...)...)
			cmd.Stdout = io.MultiWriter(f, h)
			cmd.Stderr = os.Stderr
			err = cmd.Run()
			f.Close()
			if err != nil {
				mu.Lock(); if firstErr == nil { firstErr = err }; mu.Unlock(); return
			}
			st, err := os.Stat(tp)
			if err != nil {
				mu.Lock(); if firstErr == nil { firstErr = err }; mu.Unlock(); return
			}
			layers[i] = &rawTarLayer{
				path:   tp,
				digest: v1.Hash{Algorithm: "sha256", Hex: hex.EncodeToString(h.Sum(nil))},
				size:   st.Size(),
			}
		}(i, g)
	}
	wg.Wait()
	if firstErr != nil {
		log.Fatalf("tar: %v", firstErr)
	}
	fmt.Printf("appending %d uncompressed layers (media type %s)\n", len(layers), types.OCIUncompressedLayer)

	img, err := mutate.AppendLayers(base, layers...)
	if err != nil {
		log.Fatal(err)
	}
	dref, err := name.ParseReference(finalImg+":"+version, nameOpts...)
	if err != nil {
		log.Fatal(err)
	}
	if err := remote.Write(dref, img, remote.WithAuth(auth), remote.WithJobs(len(layers)+2)); err != nil {
		log.Fatalf("push: %v", err)
	}
	fmt.Println("PUSHED", finalImg+":"+version)
}
