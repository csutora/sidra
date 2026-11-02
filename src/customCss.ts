import fs from "fs";
import path from "path";
import { app, BrowserWindow, type WebContents } from "electron";
import log from "electron-log/main";
import { liveWebContents } from "./utils";

const customCssLog = log.scope("customCss");

const CUSTOM_CSS_RELOAD_DEBOUNCE_MS = 150;
const customCssFilename = "custom.css";

let customCssKey: string | null = null;
let customCssOp: Promise<void> = Promise.resolve();

// advanced on every main-frame commit, so queued work can tell that the sheet it
// would remove or track belongs to a document that is already gone.
let documentGeneration = 0;

function customCssPath(): string {
  return path.join(app.getPath("userData"), customCssFilename);
}

function readCustomCss(): string | null {
  try {
    const css = fs.readFileSync(customCssPath(), "utf-8");
    return css.trim() === "" ? null : css;
  } catch (error) {
    const err = error as NodeJS.ErrnoException;
    if (err.code !== "ENOENT") {
      customCssLog.warn(
        "Failed to read custom.css from userData directory",
        error,
      );
    }
    return null;
  }
}

function enqueueCustomCssOp(
  work: (generation: number) => Promise<void>,
): Promise<void> {
  const generation = documentGeneration;
  customCssOp = customCssOp
    .then(() => {
      if (generation !== documentGeneration) {
        customCssKey = null;
        return;
      }
      return work(generation);
    })
    .catch((error: unknown) => {
      customCssKey = null;
      customCssLog.warn("Custom CSS operation failed", error);
    });
  return customCssOp;
}

async function insertCustomCss(
  contents: WebContents,
  generation: number,
  appliedMessage: string,
): Promise<void> {
  const css = readCustomCss();
  if (css === null) return;
  const key = await contents.insertCSS(css);
  if (generation !== documentGeneration) {
    customCssKey = null;
    return;
  }
  customCssKey = key;
  customCssLog.debug(appliedMessage);
}

/**
 * Inject custom.css after a page load, on top of the theme. The load replaced
 * the document, so any tracked key is stale and nothing is removed here.
 */
export function injectCustomCss(contents: WebContents): Promise<void> {
  return enqueueCustomCssOp(async (generation) => {
    customCssKey = null;
    await insertCustomCss(contents, generation, "custom.css injected");
  });
}

function reapplyCustomCss(win: BrowserWindow): Promise<void> {
  return enqueueCustomCssOp(async (generation) => {
    const contents = liveWebContents(win);
    if (!contents) {
      customCssKey = null;
      return;
    }
    const previousKey = customCssKey;
    if (previousKey !== null) {
      await contents.removeInsertedCSS(previousKey);
      customCssKey = null;
      if (generation !== documentGeneration) return;
    }
    await insertCustomCss(contents, generation, "custom.css re-applied");
  });
}

/**
 * Track document replacement and watch userData for custom.css changes on one
 * window. Call once.
 */
export function initCustomCss(win: BrowserWindow): void {
  win.webContents.on("did-navigate", () => {
    documentGeneration += 1;
  });

  let timer: NodeJS.Timeout | null = null;
  let watcher: fs.FSWatcher | null = null;
  const userDataPath = app.getPath("userData");
  try {
    fs.mkdirSync(userDataPath, { recursive: true });
    watcher = fs.watch(
      userDataPath,
      { persistent: false },
      (_eventType, filename) => {
        // macOS can emit a null filename for directory-level change events.
        if (filename !== null && filename.toString() !== customCssFilename)
          return;
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => {
          timer = null;
          if (win.isDestroyed()) return;
          void reapplyCustomCss(win);
        }, CUSTOM_CSS_RELOAD_DEBOUNCE_MS);
      },
    );
    watcher.on("error", (error) => {
      customCssLog.warn("custom.css watcher error", error);
    });
  } catch (error) {
    customCssLog.warn("Failed to initialise custom.css watcher", error);
  }

  win.on("closed", () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    if (watcher) {
      watcher.close();
      watcher = null;
    }
  });
}
