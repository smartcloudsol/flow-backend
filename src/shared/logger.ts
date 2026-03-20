type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR";

const LOG_LEVELS: Record<LogLevel, number> = {
  DEBUG: 0,
  INFO: 1,
  WARN: 2,
  ERROR: 3,
};

// Read from environment variable, default to INFO
const CURRENT_LOG_LEVEL: LogLevel =
  (process.env.LOG_LEVEL as LogLevel) || "INFO";

const shouldLog = (level: LogLevel): boolean => {
  return LOG_LEVELS[level] >= LOG_LEVELS[CURRENT_LOG_LEVEL];
};

export const logDebug = (message: string, data?: unknown): void => {
  if (!shouldLog("DEBUG")) return;
  console.log(
    JSON.stringify({
      level: "DEBUG",
      message,
      data,
      timestamp: new Date().toISOString(),
    }),
  );
};

export const logInfo = (message: string, data?: unknown): void => {
  if (!shouldLog("INFO")) return;
  console.log(
    JSON.stringify({
      level: "INFO",
      message,
      data,
      timestamp: new Date().toISOString(),
    }),
  );
};

export const logWarn = (message: string, data?: unknown): void => {
  if (!shouldLog("WARN")) return;
  console.warn(
    JSON.stringify({
      level: "WARN",
      message,
      data,
      timestamp: new Date().toISOString(),
    }),
  );
};

export const logError = (
  message: string,
  error?: unknown,
  data?: unknown,
): void => {
  if (!shouldLog("ERROR")) return;
  const normalized =
    error instanceof Error
      ? { name: error.name, message: error.message, stack: error.stack }
      : error;
  console.error(
    JSON.stringify({
      level: "ERROR",
      message,
      error: normalized,
      data,
      timestamp: new Date().toISOString(),
    }),
  );
};
