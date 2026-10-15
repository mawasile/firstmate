#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const [, , operation, ...args] = process.argv;

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function validId(value) {
  return typeof value === "string" && /^[A-Za-z0-9._-]+$/.test(value);
}

function validPid(value) {
  return typeof value === "string" && /^[0-9]+$/.test(value) && Number(value) > 1;
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function processName(pid) {
  const result = spawnSync("ps", ["-o", "comm=", "-p", pid], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim().split("/").at(-1) : "";
}

function writeAtomic(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, content, { mode: 0o600 });
  renameSync(temporary, path);
}

function readRecord(path) {
  try {
    const lines = readFileSync(path, "utf8").trim().split(/\r?\n/);
    const record = Object.fromEntries(lines.map((line) => {
      const index = line.indexOf("=");
      return index > 0 ? [line.slice(0, index), line.slice(index + 1)] : ["", ""];
    }));
    if (record.version !== "1" || !validId(record.session) || !validPid(record.pid)) return null;
    return record;
  } catch {
    return null;
  }
}

function removeOwnRecord(path) {
  const record = readRecord(path);
  if (record?.pid !== String(process.pid)) return;
  try {
    unlinkSync(path);
  } catch {
  }
}

function holdIsLocked(runtimePid, holdPath) {
  if (!holdPath || !existsSync(holdPath)) return null;
  const flock = spawnSync("flock", ["-n", holdPath, "-c", "true"], { stdio: "ignore" });
  if (!flock.error) return flock.status !== 0;
  const lsof = spawnSync("lsof", ["-a", "-p", runtimePid, "--", holdPath], { stdio: "ignore" });
  if (!lsof.error) return lsof.status === 0;
  return null;
}

function guard(sessionId, runtimePid, holdPath, recordPath, readyPath) {
  process.title = "fm-copilot-ses";
  const cleanup = () => {
    removeOwnRecord(recordPath);
    try {
      unlinkSync(readyPath);
    } catch {
    }
  };
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(0);
  });
  process.on("SIGINT", () => {
    cleanup();
    process.exit(0);
  });
  process.on("exit", cleanup);

  writeAtomic(
    recordPath,
    `version=1\nsession=${sessionId}\npid=${process.pid}\nruntime=${runtimePid}\n`,
  );
  closeSync(openSync(readyPath, "w", 0o600));

  let missingChecks = 0;
  const interval = setInterval(() => {
    if (!pidAlive(runtimePid)) {
      clearInterval(interval);
      cleanup();
      process.exit(0);
    }
    const locked = holdIsLocked(runtimePid, holdPath);
    if (locked === true) {
      missingChecks = 0;
      return;
    }
    if (locked === null && processName(runtimePid) === "copilot") return;
    missingChecks += 1;
    if (missingChecks < 3) return;
    clearInterval(interval);
    cleanup();
    process.exit(0);
  }, 1000);
}

function start(sessionId, runtimePid, holdPath, recordPath) {
  if (!validId(sessionId) || !validPid(runtimePid)) die("error: invalid Copilot session identity");
  const existing = readRecord(recordPath);
  if (existing?.session === sessionId && pidAlive(existing.pid) && processName(existing.pid) === "fm-copilot-ses") {
    process.stdout.write(`${existing.pid}\n`);
    return;
  }
  const readyPath = `${recordPath}.ready`;
  try {
    unlinkSync(readyPath);
  } catch {
  }
  const child = spawn(
    process.execPath,
    [process.argv[1], "guard", sessionId, runtimePid, holdPath, recordPath, readyPath],
    { detached: true, stdio: "ignore" },
  );
  child.unref();
  const startedAt = Date.now();
  while (Date.now() - startedAt < 3000) {
    if (existsSync(readyPath) && pidAlive(String(child.pid)) && processName(String(child.pid)) === "fm-copilot-ses") {
      process.stdout.write(`${child.pid}\n`);
      return;
    }
    spawnSync("sleep", ["0.02"]);
  }
  try {
    process.kill(child.pid, "SIGTERM");
  } catch {
  }
  die("error: Copilot session guardian did not become ready");
}

function stop(sessionId, recordPath) {
  if (!validId(sessionId)) die("error: invalid Copilot session identity");
  const record = readRecord(recordPath);
  if (!record || record.session !== sessionId) return;
  if (pidAlive(record.pid) && processName(record.pid) === "fm-copilot-ses") {
    try {
      process.kill(Number(record.pid), "SIGTERM");
    } catch {
    }
  }
}

switch (operation) {
  case "start":
    start(...args);
    break;
  case "stop":
    stop(...args);
    break;
  case "guard":
    guard(...args);
    break;
  default:
    die("usage: fm-copilot-session.mjs start|stop ...");
}
