#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const readline = require("node:readline");
const { spawnSync } = require("node:child_process");

const packageRoot = path.resolve(__dirname, "..");
const packageJsonPath = path.join(packageRoot, "package.json");
const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, "utf8"));

const configFiles = [
  "init.lua",
  "lazy-lock.json",
  "lua",
  "assets",
];

function usage() {
  console.log(`VibeVim ${packageJson.version}

Neovim Codex çalışma alanını kurun veya teşhis edin.

Kullanım:
  vibevim install [--yes] [--config-dir <path>]
  vibevim doctor [--config-dir <path>]
  vibevim path [--config-dir <path>]
  vibevim --version
  vibevim --help

install mevcut Neovim ayarlarını timestamp'li bir yedek olarak saklar.
--yes mevcut ayarlar için onayı otomatik verir.

Kurulumdan sonra:
  nvim`);
}

function parseArgs(rawArgs) {
  const options = {
    yes: false,
    dryRun: false,
    configDir: null,
  };
  const positional = [];

  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index];
    if (arg === "--yes" || arg === "-y" || arg === "--force") {
      options.yes = true;
    } else if (arg === "--dry-run") {
      options.dryRun = true;
    } else if (arg === "--config-dir") {
      const value = rawArgs[index + 1];
      if (!value || value.startsWith("-")) {
        throw new Error("--config-dir bir klasör yolu bekliyor.");
      }
      options.configDir = value;
      index += 1;
    } else if (arg.startsWith("--config-dir=")) {
      const value = arg.slice("--config-dir=".length);
      if (!value) {
        throw new Error("--config-dir bir klasör yolu bekliyor.");
      }
      options.configDir = value;
    } else if (arg === "--version" || arg === "-v") {
      options.version = true;
    } else if (arg === "--help" || arg === "-h") {
      options.help = true;
    } else if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg.startsWith("-")) {
      throw new Error(`Bilinmeyen seçenek: ${arg}`);
    } else {
      positional.push(arg);
    }
  }

  options.command = positional[0] || "help";
  return options;
}

function resolveConfigDir(options) {
  if (options.configDir) {
    return path.resolve(options.configDir);
  }
  if (process.env.VIBEVIM_CONFIG_DIR) {
    return path.resolve(process.env.VIBEVIM_CONFIG_DIR);
  }

  const homeDir = os.homedir();
  if (process.platform === "win32") {
    const localAppData = process.env.LOCALAPPDATA || path.join(homeDir, "AppData", "Local");
    return path.join(localAppData, "nvim");
  }
  const xdgConfigHome = process.env.XDG_CONFIG_HOME || path.join(homeDir, ".config");
  return path.join(xdgConfigHome, "nvim");
}

function exists(target) {
  try {
    fs.lstatSync(target);
    return true;
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

function realpathOrSelf(target) {
  try {
    return fs.realpathSync(target);
  } catch {
    return path.resolve(target);
  }
}

function samePath(left, right) {
  return realpathOrSelf(left) === realpathOrSelf(right);
}

function timestamp() {
  return new Date().toISOString().replace(/[.:]/g, "-");
}

function backupPath(target) {
  return `${target}.backup.${timestamp()}`;
}

function copyConfig(target) {
  for (const relativePath of configFiles) {
    const source = path.join(packageRoot, relativePath);
    if (!exists(source)) {
      // Keep the manifest ready for optional Lua modules without making an
      // empty `lua/` directory a packaging failure (npm omits empty dirs).
      if (relativePath === "lua") {
        continue;
      }
      throw new Error(`Paket dosyası eksik: ${relativePath}`);
    }
    const destination = path.join(target, relativePath);
    fs.cpSync(source, destination, {
      recursive: true,
      force: true,
      dereference: false,
    });
  }
}

function verifyInstall(target) {
  const required = [
    path.join(target, "init.lua"),
    path.join(target, "lazy-lock.json"),
  ];
  const missing = required.filter((file) => !exists(file));
  if (missing.length > 0) {
    throw new Error(`Kurulum doğrulanamadı: ${missing.join(", ")}`);
  }
}

function ask(question) {
  const prompt = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return new Promise((resolve) => {
    prompt.question(question, (answer) => {
      prompt.close();
      resolve(answer.trim().toLowerCase());
    });
  });
}

async function install(options) {
  const target = resolveConfigDir(options);
  if (samePath(packageRoot, target)) {
    console.log(`VibeVim zaten aktif yapılandırma klasöründe: ${target}`);
    return;
  }

  const targetExists = exists(target);
  if (targetExists && !options.yes && !options.dryRun) {
    if (!process.stdin.isTTY || !process.stdout.isTTY) {
      throw new Error(`${target} mevcut. Etkileşimsiz kurulum için --yes kullanın.`);
    }
    const answer = await ask(`${target} yedeklenip VibeVim kurulacak. Devam edilsin mi? [y/N] `);
    if (answer !== "y" && answer !== "yes") {
      console.log("Kurulum iptal edildi; mevcut ayarlar korunuyor.");
      return;
    }
  }

  const backup = targetExists ? backupPath(target) : null;
  if (options.dryRun) {
    console.log(`[dry-run] kaynak: ${packageRoot}`);
    console.log(`[dry-run] hedef: ${target}`);
    if (backup) {
      console.log(`[dry-run] yedek: ${backup}`);
    }
    return;
  }

  fs.mkdirSync(path.dirname(target), { recursive: true });
  let movedBackup = false;
  try {
    if (targetExists) {
      fs.renameSync(target, backup);
      movedBackup = true;
    }
    fs.mkdirSync(target, { recursive: true });
    copyConfig(target);
    verifyInstall(target);
  } catch (error) {
    if (movedBackup && !exists(target) && exists(backup)) {
      fs.renameSync(backup, target);
    }
    throw error;
  }

  console.log(`VibeVim kuruldu: ${target}`);
  if (backup) {
    console.log(`Önceki ayarlar yedeklendi: ${backup}`);
  }
  console.log("İlk nvim açılışında lazy.nvim eklentileri kurulacaktır.");
}

function commandAvailable(command) {
  const result = spawnSync(command, ["--version"], {
    stdio: "ignore",
  });
  return !result.error && result.status === 0;
}

function doctor(options) {
  const target = resolveConfigDir(options);
  const checks = [
    ["Node.js >= 18", Number.parseInt(process.versions.node, 10) >= 18],
    ["Neovim (nvim)", commandAvailable("nvim")],
    ["Git", commandAvailable("git")],
    ["VibeVim init.lua", exists(path.join(packageRoot, "init.lua"))],
    ["Kurulu config", exists(path.join(target, "init.lua"))],
  ];
  for (const [label, passed] of checks) {
    console.log(`${passed ? "✓" : "✗"} ${label}`);
  }
  console.log(`Config yolu: ${target}`);
  if (checks.some(([, passed]) => !passed)) {
    process.exitCode = 1;
  }
}

function selfTest() {
  for (const relativePath of configFiles) {
    if (!exists(path.join(packageRoot, relativePath))) {
      if (relativePath === "lua") {
        continue;
      }
      throw new Error(`Paket self-test başarısız: ${relativePath} bulunamadı.`);
    }
  }
  console.log(`VibeVim ${packageJson.version} paket self-test başarılı.`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.version) {
    console.log(packageJson.version);
    return;
  }
  if (options.selfTest) {
    selfTest();
    return;
  }
  if (options.help || options.command === "help") {
    usage();
    return;
  }
  if (options.command === "install" || options.command === "setup") {
    await install(options);
    return;
  }
  if (options.command === "doctor") {
    doctor(options);
    return;
  }
  if (options.command === "path") {
    console.log(resolveConfigDir(options));
    return;
  }
  throw new Error(`Bilinmeyen komut: ${options.command}`);
}

main().catch((error) => {
  console.error(`VibeVim: ${error.message}`);
  process.exitCode = 1;
});
