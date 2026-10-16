// Port only (his ask): the music pill follows the media player Ambxst follows
// (its MprisController: Spotify, a YouTube tab in Zen, VLC, any MPRIS player),
// as the shell reports it (shell/RoboMedia.qml), instead of Spotify alone
// through ambxst-robo (src-tauri's spotify.rs). Upstream's pill, card and
// dance rules stay as they are: what they ask of "Spotify" (Bridge.spotify*)
// goes to that player, and its reports arrive the way Spotify's did.

import { Bridge } from "@coucou/core/bridge";
import { IDLE_SPOTIFY, Spotify, type SpotifyState } from "@coucou/core/spotify";
import { applySpotify } from "@coucou/island/spotify";
import { State } from "@coucou/core/state";
import { island } from "./main";

/** What the shell does for the card: the player's own controls. */
export interface MediaHost {
  /** Bridge.spotifyControl's action and value, on the active player. */
  control(action: string, value: number | null): boolean;
  /** Brings the player's window forward (MPRIS Raise). */
  open(): boolean;
  /** Reports the player again (the card came on screen). */
  refresh(): void;
}

let host: MediaHost | null = null;

/** The active player's name ("Spotify", "Zen Browser"…), "" without one. */
export let playerName = "";

/** The shell takes over the player: every Bridge.spotify* call goes to it. */
export function attach(h: MediaHost) {
  host = h;
  const b = Bridge as unknown as Record<string, unknown>;
  b.spotifyControl = (action: string, value?: number | null) => Promise.resolve(host?.control(action, value ?? null) ?? false);
  b.spotifyOpen = () => Promise.resolve(host?.open() ?? false);
  b.spotifyRefresh = () => {
    host?.refresh();
    return Promise.resolve(Spotify.state);
  };
  // There is always a player to wait for: never "Spotify not installed".
  b.spotifyInstalled = () => Promise.resolve(true);
  // His ask: the mascot dances to whatever plays, with or without the Media pill
  // (Ambxst has its own player; upstream needs the Spotify pill declared).
  // Every dance rule reads this (island, desktop mascot, the pill's mini).
  Object.defineProperty(State, "spotifyPlaying", {
    configurable: true,
    get: () => Spotify.state.playing && Spotify.state.track != null,
  });
}

/** The active player as it is now (null: no player). */
export function report(state: SpotifyState | null, name: string) {
  playerName = name;
  const s: SpotifyState = state ?? { ...IDLE_SPOTIFY, installed: true };
  // The cover is a URL the card loads itself (https or file://), not bytes.
  const art = s.track?.artUrl ?? null;
  Spotify.artwork = art ? { artUrl: art, dataUrl: art } : null;
  if (island) applySpotify(island, s);
}
