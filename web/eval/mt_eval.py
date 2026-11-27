"""比较几种能在浏览器里跑的翻译模型：韩语课堂讲话 → 简体中文。

在 GitHub 的电脑上用 CPU 跑原版权重，只用来比“译得准不准”（chrF，越高越好）。
浏览器里用的是 4 位量化版，准确度会略低一点，但模型之间的高低顺序基本不变。
"""
import sys, time, json, os
import torch
from sacrebleu.metrics import CHRF

torch.set_num_threads(os.cpu_count() or 4)
here = os.path.dirname(os.path.abspath(__file__))
pairs = [l.rstrip("\n").split("\t") for l in open(os.path.join(here, "testset.tsv"), encoding="utf-8") if l.strip()]
src = [p[0] for p in pairs]
ref = [p[1] for p in pairs]

SYSTEM = ("你是大学课堂的韩语→简体中文同声传译。把老师说的这句韩语翻译成自然、准确的简体中文。"
          "只输出译文，不要解释，不要加引号或拼音。")


SHOTS = [
    ("자, 그럼 출석 부르고 시작하겠습니다.", "好，那我先点名，然后开始上课。"),
    ("가격탄력성이 1보다 크면 탄력적이라고 합니다", "价格弹性大于1时，就叫作富有弹性。"),
    ("이거 시험에 나오니까 잘 적어 두세요", "这个考试会考，大家好好记下来。"),
]


def run_llm(name, thinking_flag=False, dtype=torch.float32, shots=False):
    from transformers import AutoTokenizer, AutoModelForCausalLM
    tok = AutoTokenizer.from_pretrained(name)
    model = AutoModelForCausalLM.from_pretrained(name, dtype=dtype)
    model.eval()
    outs, times = [], []
    for s in src:
        msgs = [{"role": "system", "content": SYSTEM}]
        if shots:
            for k, z in SHOTS:
                msgs += [{"role": "user", "content": k}, {"role": "assistant", "content": z}]
        msgs.append({"role": "user", "content": s})
        kw = {"enable_thinking": False} if thinking_flag else {}
        prompt = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True, **kw)
        ids = tok(prompt, return_tensors="pt")
        t = time.time()
        with torch.no_grad():
            out = model.generate(**ids, max_new_tokens=120, do_sample=False)
        times.append(time.time() - t)
        text = tok.decode(out[0][ids["input_ids"].shape[1]:], skip_special_tokens=True)
        text = text.replace("<think>", "").replace("</think>", "").strip().split("\n")[0].strip()
        outs.append(text)
    return outs, times


def run_nllb(name):
    from transformers import AutoTokenizer, AutoModelForSeq2SeqLM
    tok = AutoTokenizer.from_pretrained(name, src_lang="kor_Hang")
    model = AutoModelForSeq2SeqLM.from_pretrained(name)
    outs, times = [], []
    zh = tok.convert_tokens_to_ids("zho_Hans")
    for s in src:
        ids = tok(s, return_tensors="pt")
        t = time.time()
        with torch.no_grad():
            out = model.generate(**ids, forced_bos_token_id=zh, max_new_tokens=120, num_beams=1)
        times.append(time.time() - t)
        outs.append(tok.decode(out[0], skip_special_tokens=True))
    return outs, times


def run_pivot():
    from transformers import MarianTokenizer, MarianMTModel
    a_t = MarianTokenizer.from_pretrained("Helsinki-NLP/opus-mt-ko-en")
    a_m = MarianMTModel.from_pretrained("Helsinki-NLP/opus-mt-ko-en")
    b_t = MarianTokenizer.from_pretrained("Helsinki-NLP/opus-mt-en-zh")
    b_m = MarianMTModel.from_pretrained("Helsinki-NLP/opus-mt-en-zh")
    outs, times = [], []
    for s in src:
        t = time.time()
        with torch.no_grad():
            en = a_t.decode(a_m.generate(**a_t(s, return_tensors="pt"), max_new_tokens=120)[0], skip_special_tokens=True)
            zh = b_t.decode(b_m.generate(**b_t(en, return_tensors="pt"), max_new_tokens=120)[0], skip_special_tokens=True)
        times.append(time.time() - t)
        outs.append(zh)
    return outs, times


CANDIDATES = {
    "opus-mt 韩→英→中": lambda: run_pivot(),
    "NLLB-200 600M": lambda: run_nllb("facebook/nllb-200-distilled-600M"),
    "Qwen2.5-0.5B": lambda: run_llm("Qwen/Qwen2.5-0.5B-Instruct"),
    "Qwen3-0.6B": lambda: run_llm("Qwen/Qwen3-0.6B", True),
    "Qwen2.5-1.5B": lambda: run_llm("Qwen/Qwen2.5-1.5B-Instruct"),
    "Qwen3-1.7B": lambda: run_llm("Qwen/Qwen3-1.7B", True),
    "Qwen2.5-3B": lambda: run_llm("Qwen/Qwen2.5-3B-Instruct"),
    "Qwen3.5-0.8B": lambda: run_llm("Qwen/Qwen3.5-0.8B", True),
    "Qwen3.5-2B": lambda: run_llm("Qwen/Qwen3.5-2B", True),
    "Qwen3-4B": lambda: run_llm("Qwen/Qwen3-4B", True, torch.bfloat16),
    "Qwen3.5-4B": lambda: run_llm("Qwen/Qwen3.5-4B", True, torch.bfloat16),
    # 加 3 个例句（多轮对话形式）
    "Qwen3.5-2B+例句": lambda: run_llm("Qwen/Qwen3.5-2B", True, shots=True),
    "Qwen3-1.7B+例句": lambda: run_llm("Qwen/Qwen3-1.7B", True, shots=True),
    "Qwen2.5-1.5B+例句": lambda: run_llm("Qwen/Qwen2.5-1.5B-Instruct", shots=True),
    "Qwen3-4B+例句": lambda: run_llm("Qwen/Qwen3-4B", True, torch.bfloat16, shots=True),
    "Qwen3.5-4B+例句": lambda: run_llm("Qwen/Qwen3.5-4B", True, torch.bfloat16, shots=True),
}

only = [a for arg in sys.argv[1:] for a in arg.split(",") if a.strip()] or list(CANDIDATES)
chrf = CHRF()
results = {}
for name in only:
    try:
        outs, times = CANDIDATES[name]()
    except Exception as e:  # 一个模型失败不影响其他模型
        print(f"!! {name} 失败：{e}", flush=True)
        continue
    score = chrf.corpus_score(outs, [ref]).score
    results[name] = {"chrf": score, "sec": sum(times) / len(times), "outs": outs}
    print(f"== {name}: chrF {score:.1f}, CPU 每句 {sum(times)/len(times):.2f} 秒", flush=True)

lines = ["| 模型 | chrF（越高越准） | CPU 每句秒数 |", "|---|---|---|"]
for n, r in sorted(results.items(), key=lambda kv: -kv[1]["chrf"]):
    lines.append(f"| {n} | {r['chrf']:.1f} | {r['sec']:.2f} |")
lines.append("")
for i, s in enumerate(src):
    lines.append(f"**{i+1}. {s}**  ")
    lines.append(f"参考：{ref[i]}  ")
    for n, r in results.items():
        lines.append(f"- {n}：{r['outs'][i]}")
    lines.append("")
report = "\n".join(lines)
# 机器读的结果（每个模型一行），方便把几台电脑分别跑的结果合在一起
for n, r in results.items():
    print("RESULT_JSON " + json.dumps({"name": n, "chrf": r["chrf"], "sec": r["sec"], "outs": r["outs"]}, ensure_ascii=False), flush=True)
open(os.path.join(here, "mt-report.md"), "w", encoding="utf-8").write(report)
print(report)
