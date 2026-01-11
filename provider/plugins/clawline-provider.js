const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const DEFAULT_CONFIG = {
  port: 18792,
  network: {
    bindAddress: "0.0.0.0",
    allowInsecurePublic: true,
    allowedOrigins: ["null"]
  }
};

function deepMerge(target, source) {
  if (!source || typeof source !== "object") {
    return target;
  }
  for (const [key, value] of Object.entries(source)) {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      target[key] = deepMerge({ ...(target[key] ?? {}) }, value);
    } else if (value !== undefined) {
      target[key] = value;
    }
  }
  return target;
}

function resolveConfig(contextConfig) {
  return deepMerge(JSON.parse(JSON.stringify(DEFAULT_CONFIG)), contextConfig ?? {});
}

function resolveDistPath() {
  const explicit = process.env.CLAWLINE_PROVIDER_DIST;
  if (explicit && fs.existsSync(explicit)) {
    return explicit;
  }

  const repoRelative = path.resolve(__dirname, "../dist/index.js");
  if (fs.existsSync(repoRelative)) {
    return repoRelative;
  }

  const homeDefault = path.join(os.homedir(), "src", "clawline", "provider", "dist", "index.js");
  if (fs.existsSync(homeDefault)) {
    return homeDefault;
  }

  throw new Error(
    "Unable to locate Clawline provider dist. Set CLAWLINE_PROVIDER_DIST to the compiled index.js."
  );
}

const providerModulePromise = import(pathToFileURL(resolveDistPath()).href);

let provider;

async function ensureProvider(context = {}) {
  if (provider) {
    return provider;
  }

  const logger = context.logger ?? console;
  const clawlineConfig = resolveConfig(context.config?.clawline);

  let adapter = context.adapter;
  if (!adapter && context.adapterLoader) {
    try {
      adapter = await context.adapterLoader.load(clawlineConfig.adapter);
    } catch (err) {
      logger.error?.("[clawline-provider] adapter load failed", err);
    }
  }

  if (!adapter) {
    logger.warn?.("[clawline-provider] no adapter provided; using echo adapter");
    adapter = {
      capabilities: { streaming: false },
      async execute(prompt) {
        return { exitCode: 0, output: `[echo] ${prompt}` };
      }
    };
  }

  const { createProviderServer } = await providerModulePromise;
  provider = await createProviderServer({
    config: clawlineConfig,
    adapter,
    logger
  });
  await provider.start();

  process.once("exit", () => {
    provider?.stop?.().catch(() => {});
  });

  logger.info?.(
    `[clawline-provider] listening on ${clawlineConfig.network?.bindAddress ?? "127.0.0.1"}:` +
      `${provider.getPort?.() ?? clawlineConfig.port ?? "<unknown>"}`
  );
  return provider;
}

module.exports = {
  name: "clawline-provider",
  hooks: {
    async init(context) {
      await ensureProvider(context);
      return context;
    },
    async "mcp:started"(context) {
      await ensureProvider(context);
      return context;
    }
  }
};
