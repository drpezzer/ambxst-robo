// core/sound.ts for the QML host: the same API, played by QtMultimedia in
// QML (__host.sound). Custom sounds (~/.config/ambxst-robo/sounds) are resolved on
// the QML side from Bridge.customSounds, as upstream decides which replace.
import { Bridge } from "@coucou/core/bridge";

export const SOUND_NAMES = [
  "peek", "open", "close", "hover", "blip", "slap", "annoyed", "dizzy", "greet",
  "work", "finish", "error", "approval", "question", "approve", "gulp", "tick",
  "send", "love", "pop", "proud", "wink", "yawn", "attach", "think", "search",
  "rate", "sleep", "greeting",
];

class SoundEngine {
  constructor() {
    this.enabled = true;
    this.volume = 0.12;
    this.customized = new Set();
    this.loading = null;
  }
  preload() {
    if (this.loading) return this.loading;
    this.loading = this.loadAll();
    return this.loading;
  }
  reload() { this.loading = null; return this.preload(); }
  loadAll() {
    var self = this;
    return Bridge.customSounds(SOUND_NAMES).then(function (own) {
      self.customized = new Set(own || []);
      // Resolves once the QML side knows every file: Reload's `pop` is the new one.
      return __host.sound.load(SOUND_NAMES, own || []);
    });
  }
  resume() {}
  idle() {}
  setVolume(v) { this.volume = Math.max(0, Math.min(0.2, v)); }
  setEnabled(on) { this.enabled = on; }
  play(name) {
    // Port (his ask): a helper's (subagent's) events make no sound (main.ts).
    if (!this.enabled || this.quiet) return;
    __host.sound.play(name, this.volume);
  }
  fadeOut(name, seconds) { __host.sound.fadeOut(name, seconds); }
}

export const Sound = new SoundEngine();
