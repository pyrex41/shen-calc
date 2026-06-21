//! English mode: a small on-device model (Qwen3-0.6B, GGUF/quantized) run via
//! candle, Metal-accelerated on Apple silicon. The model only maps a natural-
//! language question to ONE tool call from [`crate::grammar`]; Rust assembles
//! the CAS expression and shen-cas does the math, so the model can't produce a
//! wrong answer — only a tool call the CAS rejects.
//!
//! Gated behind the `nl` cargo feature (candle is a heavy build): the base app
//! ships Syntax mode and compiles fast without it.

use candle_core::quantized::gguf_file;
use candle_core::{DType, Device, Tensor};
use candle_transformers::generation::LogitsProcessor;
use candle_transformers::models::quantized_qwen3::ModelWeights;
use hf_hub::api::sync::Api;
use tokenizers::Tokenizer;

/// Hugging Face sources. The GGUF carries the weights; the tokenizer.json comes
/// from the base repo (candle drives the `tokenizers` crate, not the embedded
/// GGUF vocab).
const GGUF_REPO: &str = "unsloth/Qwen3-0.6B-GGUF";
const GGUF_FILE: &str = "Qwen3-0.6B-Q4_K_M.gguf";
const TOKENIZER_REPO: &str = "Qwen/Qwen3-0.6B";

/// Cap generation — a tool call is one short line; this just bounds a runaway.
const MAX_NEW_TOKENS: usize = 96;

pub struct NlModel {
    model: ModelWeights,
    tokenizer: Tokenizer,
    device: Device,
    eos: u32,
}

impl NlModel {
    /// Download (first run) and load the model + tokenizer.
    pub fn load() -> Result<Self, String> {
        // CPU, not Metal: candle's Metal backend has no rms-norm kernel for the
        // quantized Qwen3 path ("no metal implementation for rms-norm"). A 0.6B
        // Q4 model decodes a one-line tool call fast enough on CPU, and the
        // grammar contract means we only need a handful of tokens.
        let device = Device::Cpu;

        let api = Api::new().map_err(|e| format!("hf-hub: {e}"))?;
        let gguf_path = api
            .model(GGUF_REPO.to_string())
            .get(GGUF_FILE)
            .map_err(|e| format!("download {GGUF_FILE}: {e}"))?;
        let tok_path = api
            .model(TOKENIZER_REPO.to_string())
            .get("tokenizer.json")
            .map_err(|e| format!("download tokenizer: {e}"))?;

        let tokenizer = Tokenizer::from_file(&tok_path).map_err(|e| format!("tokenizer: {e}"))?;
        let eos = tokenizer.token_to_id("<|im_end|>").unwrap_or(151645);

        let mut file = std::fs::File::open(&gguf_path).map_err(|e| format!("open gguf: {e}"))?;
        let content = gguf_file::Content::read(&mut file).map_err(|e| format!("read gguf: {e}"))?;
        let model = ModelWeights::from_gguf(content, &mut file, &device)
            .map_err(|e| format!("load weights: {e}"))?;

        Ok(Self { model, tokenizer, device, eos })
    }

    /// Run one completion: format the chat prompt, greedily decode the tool
    /// call, and return the model's text (pre-grammar-parse).
    pub fn complete(&mut self, system: &str, user: &str) -> Result<String, String> {
        self.model.clear_kv_cache();
        // Qwen3 ChatML, with thinking disabled by pre-filling an empty <think>
        // block (equivalent to the template's enable_thinking=false) so a 0.6B
        // model goes straight to the tool call instead of reasoning aloud.
        let prompt = format!(
            "<|im_start|>system\n{system}<|im_end|>\n\
             <|im_start|>user\n{user}<|im_end|>\n\
             <|im_start|>assistant\n<think>\n\n</think>\n\n"
        );

        let encoding = self
            .tokenizer
            .encode(prompt, true)
            .map_err(|e| format!("encode: {e}"))?;
        let prompt_tokens = encoding.get_ids().to_vec();

        let mut logits_processor = LogitsProcessor::new(42, None, None); // greedy
        let mut out_tokens: Vec<u32> = Vec::new();

        // Prime the KV cache with the full prompt (offset 0), then decode one
        // token at a time advancing the offset.
        let mut next = self.sample(&prompt_tokens, 0, &mut logits_processor)?;
        let mut pos = prompt_tokens.len();
        for _ in 0..MAX_NEW_TOKENS {
            if next == self.eos {
                break;
            }
            out_tokens.push(next);
            next = self.sample(&[next], pos, &mut logits_processor)?;
            pos += 1;
        }

        self.tokenizer
            .decode(&out_tokens, true)
            .map_err(|e| format!("decode: {e}"))
    }

    /// Forward `tokens` at `offset` and sample the next token id.
    fn sample(
        &mut self,
        tokens: &[u32],
        offset: usize,
        lp: &mut LogitsProcessor,
    ) -> Result<u32, String> {
        let input = Tensor::new(tokens, &self.device)
            .and_then(|t| t.unsqueeze(0))
            .map_err(|e| format!("input tensor: {e}"))?;
        let logits = self
            .model
            .forward(&input, offset)
            .map_err(|e| format!("forward: {e}"))?;
        // Quantized qwen3 returns last-token logits as [1, vocab]; reduce to a
        // 1-D f32 vector for the sampler (handle [1, seq, vocab] defensively).
        let logits = logits.squeeze(0).map_err(|e| format!("squeeze: {e}"))?;
        let logits = if logits.rank() == 2 {
            let last = logits.dim(0).map_err(|e| e.to_string())? - 1;
            logits.get(last).map_err(|e| format!("last row: {e}"))?
        } else {
            logits
        };
        let logits = logits
            .to_dtype(DType::F32)
            .map_err(|e| format!("f32: {e}"))?;
        lp.sample(&logits).map_err(|e| format!("sample: {e}"))
    }
}
