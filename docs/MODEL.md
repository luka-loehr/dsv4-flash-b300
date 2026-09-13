# Model and quantization

- **Model**: [`prem-research/DeepSeek-V4-Flash-0731-abliterated`](https://huggingface.co/prem-research/DeepSeek-V4-Flash-0731-abliterated) (156 GB native checkpoint).
- **Dense weights**: block-128 FP8 (`e4m3`) with DeepGEMM.
- **MoE experts**: block-32 packed FP4 (`e2m1`) via FlashInfer TRTLLM-GEN.
- **Speculative decoding**: DSpark draft weights from `mtp.{0,1,2}.*` with a
  rank-256 Markov head (`dspark_markov_rank: 256`, target layers `[40,41,42]`).
- **Attention**: FlashInfer MLA with native `fp8_ds_mla` + FP4 Lightning-Indexer cache.

## Abliteration and responsible use

The abliteration (ARA, refusal steering with low capability drift) was done
upstream; this repository only provides the serving stack. Because safety refusals
were removed, the model will answer requests that the original model would decline.

You are solely responsible for how you use this model and its outputs, and for
complying with applicable laws and with the terms of every provider involved, such
as RunPod (hosting), Anthropic (Claude Code) and OpenAI (Codex).

## License and credits

The image redistributes the checkpoint unmodified, under its upstream MIT license:

- DeepSeek-V4-Flash by [DeepSeek](https://huggingface.co/deepseek-ai)
- Abliterated variant by [prem-research](https://huggingface.co/prem-research/DeepSeek-V4-Flash-0731-abliterated)
  (see the model card for the license text)

The weights remain the property of their respective authors. The code in this
repository is MIT-licensed separately ([LICENSE](../LICENSE)).
