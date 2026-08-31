// build-runtime — assemble the runtime image from an already-installed rootfs:
// pytorch base + one uncompressed layer of the runtime additions
// (/opt/venvs/dsv4 vLLM venv, /root/.cache/flashinfer cubins, scripts, entrypoint)
// + the Dockerfile's ENV/ENTRYPOINT. No gzip (fast push + fast extract).
//
// Env: BASE_IMG FINAL_IMG RUNTIME_TAR INSECURE
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log"
	"os"
	"strings"

	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/types"
)

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

func main() {
	var nameOpts []name.Option
	if os.Getenv("INSECURE") == "1" {
		nameOpts = append(nameOpts, name.Insecure)
	}
	baseRef := os.Getenv("BASE_IMG")
	finalRef := os.Getenv("FINAL_IMG")
	tarPath := os.Getenv("RUNTIME_TAR")

	bref, err := name.ParseReference(baseRef, nameOpts...)
	if err != nil {
		log.Fatal(err)
	}
	base, err := remote.Image(bref)
	if err != nil {
		log.Fatalf("read base: %v", err)
	}

	// hash the runtime tar (digest == diffID for an uncompressed layer)
	f, err := os.Open(tarPath)
	if err != nil {
		log.Fatal(err)
	}
	h := sha256.New()
	sz, err := io.Copy(h, f)
	f.Close()
	if err != nil {
		log.Fatal(err)
	}
	lyr := &rawTarLayer{path: tarPath, digest: v1.Hash{Algorithm: "sha256", Hex: hex.EncodeToString(h.Sum(nil))}, size: sz}

	img, err := mutate.AppendLayers(base, lyr)
	if err != nil {
		log.Fatal(err)
	}

	// set the Dockerfile's ENV + ENTRYPOINT (preserve base env, prepend venv to PATH)
	cfg, err := img.ConfigFile()
	if err != nil {
		log.Fatal(err)
	}
	c := cfg.DeepCopy()
	venvBin := "/opt/venvs/dsv4/bin"
	havePath := false
	for i, e := range c.Config.Env {
		if strings.HasPrefix(e, "PATH=") {
			c.Config.Env[i] = "PATH=" + venvBin + ":" + strings.TrimPrefix(e, "PATH=")
			havePath = true
		}
	}
	if !havePath {
		c.Config.Env = append(c.Config.Env, "PATH="+venvBin+":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	}
	c.Config.Env = append(c.Config.Env,
		"FLASHINFER_CUBIN_DIR=/root/.cache/flashinfer/cubins",
		"DSV4_PROFILE=fast",
		"DSV4_MODEL=/models/DeepSeek-V4-Flash-0731-abliterated",
		"HF_HUB_DISABLE_TELEMETRY=1",
		"PORT=8000",
	)
	c.Config.Entrypoint = []string{"/usr/local/bin/dsv4-entrypoint"}
	c.Config.Cmd = nil
	img, err = mutate.ConfigFile(img, c)
	if err != nil {
		log.Fatal(err)
	}

	dref, err := name.ParseReference(finalRef, nameOpts...)
	if err != nil {
		log.Fatal(err)
	}
	if err := remote.Write(dref, img, remote.WithJobs(4)); err != nil {
		log.Fatalf("push: %v", err)
	}
	log.Println("RUNTIME_IMAGE_PUSHED", finalRef)
}
