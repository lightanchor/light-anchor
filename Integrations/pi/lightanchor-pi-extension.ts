// lightanchor-integration-version: 1
// 轻锚 · PI（@earendil-works/pi-coding-agent）扩展
//
// 把 PI 会话的回合翻译成轻锚外部事件：
//   agent_start      -> started    （回合开始，等待重新打开）
//   agent_settled    -> completed  （回合真正落定，等待变成「可以返回」；
//                                    不用 agent_end——重试和排队消息还会继续跑）
//   session_shutdown -> cancelled  （会话关闭；已就绪的结果保持就绪）
//
// 隐私边界：只发送进程号（做关联）、项目目录名和一句状态说明；
// 不发送 prompt、模型输出或任何文件内容。发布失败一律静默。
//
// 安装方式见同目录说明：把本文件放进
// ~/.pi/agent/extensions/（pi 的全局自动发现目录），删除即卸载。

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";

const correlation = `pi-${process.pid}`;
const title = `PI · ${basename(process.cwd()) || "会话"}`;

function resolvePublisher(): string | null {
  const fromEnvironment = process.env.LIGHTANCHOR_EVENT_BIN;
  if (fromEnvironment && existsSync(fromEnvironment)) return fromEnvironment;
  const installed = `${homedir()}/Library/Application Support/LightAnchor/Integrations/lightanchor-event`;
  if (existsSync(installed)) return installed;
  return null;
}

function publish(kind: string, detail: string) {
  const bin = resolvePublisher();
  if (!bin) return;
  try {
    const child = spawn(
      bin,
      [
        "publish",
        "--source", "agent",
        "--kind", kind,
        "--correlation", correlation,
        "--title", title,
        "--detail", detail,
        "--cwd", process.cwd(),
      ],
      { stdio: "ignore", detached: true },
    );
    child.on("error", () => {});
    child.unref();
  } catch {
    // 发布器不在也不能影响 pi 本身。
  }
}

export default function (pi: any) {
  pi.on("agent_start", async () => {
    publish("started", "正在处理你的请求");
  });
  pi.on("agent_settled", async () => {
    publish("completed", "回合结束，等你回看");
  });
  pi.on("session_shutdown", async () => {
    publish("cancelled", "会话已结束");
  });
}
