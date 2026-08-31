# DSpark Speculative Decoding on Blackwell

DeepSeek-V4-Flash introduces an advanced speculative decoding module known internally as **DSpark**.

---

## 1. DSpark vs Standard MTP

| Feature | Standard MTP (Multi-Token Prediction) | DeepSeek DSpark |
| :--- | :--- | :--- |
| **Draft Module Count** | Single linear projection head | 3 full transformer draft layers (`mtp.0/1/2`) |
| **Target Layers** | Top layer only | Selected mid-to-high layers (`[40, 41, 42]`) |
| **Markov Acceleration** | None | Rank-256 Markov transition head (`markov_w1/w2`) |
| **Weights Storage** | Separate draft checkpoint | Embedded directly inside main checkpoint |
| **Sampling Method** | Greedy argmax | Configurable probabilistic / greedy |

---

## 2. Verified Implementation in vLLM

In `vllm/models/deepseek_v4/nvidia/dspark.py`:

```python
class DSparkDeepseekV4ForCausalLM(nn.Module):
    # Loads mtp.{0,1,2}.* from the main checkpoint:
    # num_dspark_layers = 3
    # dspark_markov_rank = 256
    # dspark_target_layer_ids = [40, 41, 42]
```

### Launch Flags
To enable DSpark in vLLM with 7 speculative candidate tokens and probabilistic draft sampling:
```bash
--speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}'
```

---

## 3. Measured Acceptance Breakdown

Measured during live single-stream code generation on the NVIDIA B300:

```text
========================================================================
DSPARK SPECULATIVE METRICS
========================================================================
Mean Acceptance Length : 3.79 tokens / step
Average Draft Rate     : 39.9%
Per-Position Acceptance:
  Position 1 : 81.1%
  Position 2 : 64.2%
  Position 3 : 47.2%
  Position 4 : 34.0%
  Position 5 : 32.1%
  Position 6 : 17.0%
  Position 7 :  3.8%
========================================================================
```
