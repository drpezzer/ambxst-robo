// views/spotify.ts without the DOM: the controls the Spotify card and pill
// call (play/pause, seek, shuffle/repeat, volume with its 120 ms throttle) and
// what the card shows. SpotifyCard.qml / SpotifyPill.qml render it.

import { Bridge } from "@coucou/core/bridge";
import { State } from "@coucou/core/state";
import {
  SPOTIFY_GREEN, SPOTIFY_ID, Spotify, currentArtwork, formatTime, isAd, spotifyPosition, volumeLevel,
} from "@coucou/core/spotify";
import { togglePlay } from "@coucou/views/spotify";
import { pillDefinition } from "@coucou/core/pills";
import { N_, t } from "@coucou/i18n/i18n";
import { ICONS } from "@coucou/views/icons";
import * as Media from "../media";

export { togglePlay };

export function next() {
  void Bridge.spotifyControl("next");
}

export function previous() {
  void Bridge.spotifyControl("previous");
}

export function openSpotify() {
  void Bridge.spotifyOpen();
}

/** seek(): at once on the page, then in Spotify. */
export function seek(seconds: number) {
  const s = Spotify.state;
  const track = s.track;
  if (!s.running || !track || isAd(track)) return;
  const target = Math.min(Math.max(0, seconds), Math.max(0, track.duration - 1));
  Spotify.state = { ...s, position: target, positionAt: Date.now() };
  State.notify();
  void Bridge.spotifyControl("seek", target);
}

export function setFlag(which: "shuffle" | "repeat", on: boolean) {
  if (!Spotify.state.running) return;
  Spotify.state = { ...Spotify.state, [which]: on };
  State.notify();
  void Bridge.spotifyControl(which, on ? 1 : 0);
}

// A slider drag sends at most one volume every 120 ms (SpotifyController.setVolume).
let pendingVolume: number | null = null;
let volumeTimer: number | null = null;

export function setVolume(value: number) {
  if (!Spotify.state.running) return;
  const v = Math.min(100, Math.max(0, Math.round(value)));
  Spotify.state = { ...Spotify.state, volume: v };
  State.notify();
  pendingVolume = v;
  if (volumeTimer != null) return;
  const send = () => {
    const nextV = pendingVolume;
    pendingVolume = null;
    if (nextV == null) {
      volumeTimer = null;
      return;
    }
    void Bridge.spotifyControl("volume", nextV);
    volumeTimer = setTimeout(send, 120) as unknown as number;
  };
  send();
}

/** Everything the card shows apart from the running progress. */
export function card() {
  const s = Spotify.state;
  const track = s.track;
  // Port (his ask): any MPRIS player (lib/media.ts), named after itself.
  const player = Media.playerName;
  if (!track) {
    return {
      playing: false, hasTrack: false, name: player || t("Media"),
      idleColor: s.running ? "#22C55E" : "#6B7079",
      idleText: s.running ? t("Not playing") : t("Nothing playing"),
      idleAction: s.running && player ? t("Open {0}", { 0: player }) : "",
      subtitle: t(pillDefinition(SPOTIFY_ID)?.subtitle ?? N_("Integration")),
    };
  }
  const sub = [track.artist, track.album].filter((x) => x).join(" · ");
  return {
    playing: s.playing, hasTrack: true,
    title: isAd(track) ? t("Advertisement") : track.title,
    sub,
    name: player || t("Media"),
    artTitle: player ? (track.album ? `${track.album} — ${t("Open {0}", { 0: player })}` : t("Open {0}", { 0: player })) : track.album,
    cover: currentArtwork(s) ?? "",
    seekable: !isAd(track) && track.duration > 0,
    duration: track.duration,
    shuffle: s.shuffle, repeat: s.repeat,
    shuffleColor: s.shuffle ? SPOTIFY_GREEN : "#6B7079",
    repeatColor: s.repeat ? SPOTIFY_GREEN : "#6B7079",
    shuffleTitle: s.shuffle ? t("Shuffle on") : t("Shuffle off"),
    repeatTitle: s.repeat ? t("Repeat on") : t("Repeat off"),
    playTitle: s.playing ? t("Pause") : t("Play"),
    volume: s.volume,
    volumeIcon: [ICONS.volume0, ICONS.volume1, ICONS.volume2, ICONS.volume3][volumeLevel(s.volume)],
    volumeTitle: t("Volume {0}%", { 0: s.volume }),
  };
}

/** paintProgress(): fraction, elapsed and remaining at `nowMs`, or while dragging. */
export function progress(nowMs: number, dragFraction: number | null) {
  const s = Spotify.state;
  const d = s.track?.duration ?? 0;
  const pos = dragFraction != null ? dragFraction * d : spotifyPosition(s, nowMs);
  const f = dragFraction ?? (d > 0 ? Math.min(1, Math.max(0, pos / d)) : 0);
  return {
    fraction: f,
    elapsed: formatTime(f * d),
    remaining: d > 0 ? `-${formatTime(Math.max(0, d - f * d))}` : "",
  };
}

/** syncTimer(): the position runs on while it plays on screen. */
export function clockRuns(): boolean {
  return Spotify.state.playing && Spotify.state.track != null && State.mode === "expanded" && State.view === "overview";
}

/** The pill: the hover controls show once a track is loaded. */
export function pill() {
  const s = Spotify.state;
  return {
    hasTrack: s.track != null,
    playing: s.playing,
    playTitle: s.playing ? t("Pause") : t("Play"),
    nextTitle: t("Next"),
  };
}

export const dancing = () => State.spotifyPlaying;
