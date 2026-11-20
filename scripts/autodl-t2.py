#!/usr/bin/env python3
"""T2 训练驱动（scripts/autodl-t2.py）：创建 AutoDL 实例 → 装环境 → 上传数据 → 发起 QLoRA 训练。

前置：AutoDL 账号完成个人实名认证（Pro API 硬要求）；充值 ≥¥50；API Token 已存钥匙串（autodl-api）。
用法：
  python3 scripts/autodl-t2.py create     # 创建 4090D 实例并打印 SSH 命令
  python3 scripts/autodl-t2.py setup      # 远程装环境（torch + llama-factory + 下载基座）
  python3 scripts/autodl-t2.py upload     # 上传 datasets/sinan-sft/train.jsonl
  python3 scripts/autodl-t2.py train      # 发起 QLoRA SFT（nohup，训练中可断开）
  python3 scripts/autodl-t2.py status     # 看训练进度
  python3 scripts/autodl-t2.py fetch      # 取回 LoRA 合并产物到 datasets/sinan-sft/merged/
  python3 scripts/autodl-t2.py release    # 释放实例（停止计费）
令牌从钥匙串读：security find-generic-password -s autodl-api -w
"""
import json, os, subprocess, sys, time, pathlib

HOST = "https://api.autodl.com"
INSTANCE = "sinan-t2-qlora"
SPEC = "4090D"          # 24GB，约 ¥2/小时
IMAGE = "base-image-l2t43iu6uk"   # cuda11.8 + torch2.0 + conda（容器内自装新环境）
BASE_MODEL = "Qwen/Qwen3-0.6B"    # 从 ModelScope 拉，国内快

def token():
    return subprocess.run(["security", "find-generic-password", "-s", "autodl-api", "-w"],
                          capture_output=True, text=True).stdout.strip()

def api(method, path, body=None):
    import urllib.request
    req = urllib.request.Request(HOST + path,
                                 data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": token(), "Content-Type": "application/json"},
                                 method=method)
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())

def find_instance():
    # 备援：手动在控制台租的实例没有 Pro API 记录，用 AUTO_SSH 环境变量直接给
    # ssh 命令（AutoDL 控制台复制："ssh -p XXXXX root@connect.xx.autodl.com"）
    manual = os.environ.get("AUTO_SSH")
    if manual:
        return {"ssh_command": manual}
    d = api("GET", "/api/v1/dev/instance/pro/list")
    for it in d.get("data", {}).get("list", []):
        if it.get("instance_name") == INSTANCE or it.get("instance_uuid", "").startswith("pro-") and INSTANCE in str(it.get("instance_name")):
            return it
    # 兜底：按备注名精确匹配
    for it in d.get("data", {}).get("list", []):
        if it.get("instance_name") == INSTANCE:
            return it
    return None

def ssh_cmd(it):
    c = it.get("ssh_command") or ""
    return c

def run_remote(it, script, timeout=3600):
    """通过 ssh 在实例上执行脚本（AutoDL 默认 root 登录）。"""
    import re
    m = re.match(r"ssh -p (\d+) root@([\w.]+)", ssh_cmd(it))
    if not m:
        print("SSH 命令解析失败:", ssh_cmd(it)); sys.exit(1)
    port, host = m.groups()
    subprocess.run(["ssh", "-p", port, "-o", "StrictHostKeyChecking=no", f"root@{host}", script], timeout=timeout)

def create():
    r = api("POST", "/api/v1/dev/instance/pro/create", {
        "gpu_spec_uuid": SPEC,
        "image_uuid": IMAGE,
        "cuda_v_from": 118,
        "req_gpu_amount": 1,
        "expand_system_disk_by_gb": 50,
        "instance_name": INSTANCE,
        "start_command": "sleep infinity",
    })
    print(json.dumps(r, ensure_ascii=False))
    if r.get("code") == "Success":
        print("创建成功，等待开机后执行 setup（约 1-2 分钟）")

def setup():
    it = find_instance()
    if not it: print("先 create"); sys.exit(1)
    script = '''
set -e
source /etc/network_turbo 2>/dev/null || true
conda create -y -n sinan python=3.11 || true
source activate sinan
pip install -q torch==2.4.0 transformers==4.51.3 datasets accelerate peft trl setproctitle
pip install -q modelscope
python -c "from modelscope import snapshot_link" 2>/dev/null || true
python - <<'PY'
from modelscope import snapshot_download
p = snapshot_download("Qwen/Qwen3-0.6B")
print("MODEL_PATH:", p)
PY
'''
    run_remote(it, script, timeout=1800)

def upload():
    it = find_instance()
    import re
    m = re.match(r"ssh -p (\d+) root@([\w.]+)", it.get("ssh_command") or "")
    port, host = m.groups()
    f = pathlib.Path.home() / "Projects/cra/datasets/sinan-sft/train.jsonl"
    subprocess.run(["scp", "-P", port, "-o", "StrictHostKeyChecking=no", str(f), f"root@{host}:/root/train.jsonl"], check=True)
    print("train.jsonl 已上传")

def train():
    it = find_instance()
    script = """
set -e
source activate sinan
mkdir -p /root/data
python3 - <<'PY'
import json
rows = [json.loads(l) for l in open("/root/train.jsonl")]
out = []
for d in rows:
    msgs = d["messages"]
    sysm = next((m["content"] for m in msgs if m["role"] == "system"), "")
    user = next((m["content"] for m in msgs if m["role"] == "user"), "")
    asst = next((m["content"] for m in msgs if m["role"] == "assistant"), "")
    out.append({"instruction": user, "input": "", "output": asst, "system": sysm})
with open("/root/data/sinan.jsonl", "w") as f:
    for r in out:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
print("converted", len(out))
PY
cat > /root/dataset_info.json <<'J'
{"sinan": {"file_name": "/root/data/sinan.jsonl", "formatting": "alpaca", "columns": {"prompt": "instruction", "query": "input", "response": "output", "system": "system"}}}
J
cat > /root/sft.yaml <<'YAML'
model_name_or_path: /root/.cache/modelscope/hub/models/Qwen/Qwen3-0.6B
stage: sft
do_train: true
finetuning_type: lora
lora_target: all
lora_rank: 16
lora_alpha: 32
dataset: sinan
dataset_info_path: /root/dataset_info.json
template: qwen3
cutoff_len: 2048
per_device_train_batch_size: 8
gradient_accumulation_steps: 2
learning_rate: 2.0e-4
num_train_epochs: 3.0
bf16: true
output_dir: /root/sinan-lora
logging_steps: 10
save_steps: 200
YAML
nohup llamafactory-cli train /root/sft.yaml > /root/train.log 2>&1 &
echo "training started: /root/train.log"
"""
    run_remote(it, script, timeout=120)

def status():
    it = find_instance()
    run_remote(it, "tail -5 /root/train.log; nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader", timeout=60)

def fetch():
    it = find_instance()
    import re
    m = re.match(r"ssh -p (\d+) root@([\w.]+)", it.get("ssh_command") or "")
    port, host = m.groups()
    out = pathlib.Path.home() / "Projects/cra/datasets/sinan-sft/merged"
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(["scp", "-P", port, "-o", "StrictHostKeyChecking=no",
                    f"root@{host}:/root/sinan-lora/adapter_model.safetensors", str(out) + "/"], check=True)
    print("LoRA 产物已取回", out)

def release():
    it = find_instance()
    uuid = it.get("instance_uuid")
    r = api("POST", "/api/v1/dev/instance/pro/release", {"instance_uuid": uuid})
    print(json.dumps(r, ensure_ascii=False))

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    globals()[cmd]()
