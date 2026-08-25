// lightanchor-integration-version: 1
// 轻锚 · dsh（DeepSeek Harness）cordis 插件
//
// 订阅 agent/status，把每个 agent 的回合翻译成轻锚外部事件：
//   running -> started    （回合开始，等待重新打开）
//   idle    -> completed  （回合结束，等待变成「可以返回」）
//   error   -> failed     （出错同样是「可以返回」的结果）
//
// 隐私边界：只发送进程号与 agent 标识（做关联）、项目目录名和一句
// 状态说明；不发送消息内容或任何文件内容。发布失败一律静默。
//
// 安装方式：在每个 profile 的 cordis.patch.yml 里挂一条指向本文件绝对
// 路径的插件项，删掉那条即卸载。
"use strict";

const { spawn } = require("node:child_process");
const { existsSync } = require("node:fs");
const { homedir } = require("node:os");
const { basename } = require("node:path");

const title = `dsh · ${basename(process.cwd()) || "会话"}`;

function resolvePublisher() {
  const fromEnvironment = process.env.LIGHTANCHOR_EVENT_BIN;
  if (fromEnvironment && existsSync(fromEnvironment)) return fromEnvironment;
  const installed = `${homedir()}/Library/Application Support/LightAnchor/Integrations/lightanchor-event`;
  if (existsSync(installed)) return installed;
  return null;
}

function publish(correlation, kind, detail) {
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
    // 发布器不在也不能影响 dsh 本身。
  }
}

function agentKey(agent) {
  if (typeof agent === "string") return agent;
  if (agent && typeof agent === "object") {
    if (typeof agent.id === "string") return agent.id;
    if (typeof agent.name === "string") return agent.name;
  }
  return "agent";
}

exports.name = "lightanchor";

exports.apply = (ctx) => {
  ctx.on("agent/status", ({ agent, status }) => {
    const correlation = `dsh-${process.pid}-${agentKey(agent)}`;
    if (status === "running") {
      publish(correlation, "started", "正在处理你的请求");
    } else if (status === "idle") {
      publish(correlation, "completed", "回合结束，等你回看");
    } else if (status === "error") {
      publish(correlation, "failed", "运行出错，回去看一眼");
    }
  });
};
