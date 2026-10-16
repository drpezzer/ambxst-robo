import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.modules.services
import qs.modules.robo as C

// Port only (his ask): Robo's music pill follows the media player Ambxst
// follows — MprisController.activePlayer, the one the dashboard's player and
// the bar show: Spotify, a YouTube tab in Zen, VLC… — instead of Spotify
// alone through ambxst-robo. Reported to lib/media.ts in the shape upstream's
// Spotify reports have (core/spotify.ts SpotifyState); the card's controls
// come back here. The mascot dances to whatever plays, as he did to Spotify.
Scope {
    id: root
    readonly property var player: MprisController.activePlayer
    readonly property var lib: C.Robo.lib
    readonly property bool ready: C.Robo.island !== null

    function state() {
        const p = root.player;
        if (!p)
            return null;
        const title = p.trackTitle || "";
        const art = MprisController.artUrlFor(p) || "";
        const meta = p.metadata || {};
        // mpris:trackid is a D-Bus object path (it stringifies as debug text):
        // Spotify's names the track, anyone else's the page or the title does.
        const rawId = String(meta["mpris:trackid"] || "");
        const spotifyId = (rawId.match(/\/com\/spotify\/(track|episode|ad)\/([A-Za-z0-9]+)/) || []);
        const trackId = spotifyId.length ? `spotify:${spotifyId[1]}:${spotifyId[2]}` : String(meta["xesam:url"] || title);
        return {
            running: true,
            installed: true,
            track: title === "" ? null : {
                // Upstream reads "spotify:ad:" ids as adverts; other players never match.
                id: trackId.startsWith("spotify:") ? trackId : `mpris:${p.dbusName}:${trackId}`,
                title: title,
                artist: p.trackArtist || "",
                album: p.trackAlbum || "",
                duration: p.lengthSupported && p.length > 0 ? p.length : 0,
                artUrl: art !== "" ? art : null,
            },
            playing: p.isPlaying,
            position: p.positionSupported ? p.position : 0,
            positionAt: Date.now(),
            shuffle: p.shuffleSupported ? p.shuffle : false,
            repeat: p.loopSupported ? p.loopState !== MprisLoopState.None : false,
            volume: p.volumeSupported ? Math.round(p.volume * 100) : 100,
        };
    }

    /** "Mozilla zen" → "Zen"; "Spotify", "VLC media player" stay as they are. */
    function nameOf(p) {
        const n = (p.identity || p.desktopEntry || "").replace(/^Mozilla\s+/i, "");
        return n ? n.charAt(0).toUpperCase() + n.slice(1) : "";
    }

    function report() {
        if (!root.ready)
            return;
        const p = root.player;
        root.lib.Media.report(root.state(), p ? root.nameOf(p) : "");
    }

    /** Bridge.spotifyControl's actions (lib/media.ts), on the player itself. */
    function control(action, value) {
        const p = root.player;
        if (!p)
            return false;
        switch (action) {
        case "playPause":
            if (!p.canTogglePlaying)
                return false;
            p.togglePlaying();
            break;
        case "next":
            if (!p.canGoNext)
                return false;
            p.next();
            break;
        case "previous":
            if (!p.canGoPrevious)
                return false;
            p.previous();
            break;
        case "seek":
            if (!p.canSeek || value === null)
                return false;
            p.position = value;
            break;
        case "shuffle":
            if (!p.shuffleSupported)
                return false;
            p.shuffle = !!value;
            break;
        case "repeat":
            if (!p.loopSupported)
                return false;
            p.loopState = value ? MprisLoopState.Playlist : MprisLoopState.None;
            break;
        case "volume":
            if (!p.volumeSupported || value === null)
                return false;
            p.volume = Math.max(0, Math.min(100, value)) / 100;
            break;
        default:
            return false;
        }
        later.restart();
        return true;
    }

    function attach() {
        if (!root.ready)
            return;
        C.Robo.mediaFromShell = true;
        root.lib.Media.attach({
            control: (action, value) => root.control(action, value),
            open: () => {
                const p = root.player;
                if (!p || !p.canRaise)
                    return false;
                p.raise();
                return true;
            },
            refresh: () => later.restart()
        });
        root.report();
    }

    onReadyChanged: attach()
    Component.onCompleted: attach()
    onPlayerChanged: later.restart()

    // Many properties change at once on a new track: one report for them all.
    Timer {
        id: later
        interval: 40
        onTriggered: root.report()
    }

    Connections {
        target: root.player
        ignoreUnknownSignals: true
        function onTrackTitleChanged() { later.restart(); }
        function onTrackArtistChanged() { later.restart(); }
        function onTrackAlbumChanged() { later.restart(); }
        function onTrackArtUrlChanged() { later.restart(); }
        function onMetadataChanged() { later.restart(); }
        function onLengthChanged() { later.restart(); }
        function onIsPlayingChanged() { later.restart(); }
        function onPlaybackStateChanged() { later.restart(); }
        // A seek (MPRIS Seeked): the clock restarts from there. Ambxst's own
        // slider nudges positionChanged every second while playing; the card
        // runs its clock itself, so only a real jump is reported.
        function onPositionChanged() {
            const p = root.player;
            if (!p || !p.positionSupported)
                return;
            const s = root.lib.Spotify.Spotify.state;
            const expected = s.position + (s.playing ? Math.max(0, (Date.now() - s.positionAt) / 1000) : 0);
            if (Math.abs(p.position - expected) > 1.5)
                later.restart();
        }
        function onShuffleChanged() { later.restart(); }
        function onLoopStateChanged() { later.restart(); }
        function onVolumeChanged() { later.restart(); }
        function onIdentityChanged() { later.restart(); }
    }
}
