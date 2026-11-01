# mpd-small's features plus pipewire, on prev.mpd: aliasing prev.mpd-small recurses.
# Re-check the list on a nixpkgs bump.
final: prev: {
  mpd = prev.mpd.override {
    features = [
      "webdav"
      "curl"
      "mms"
      "bzip2"
      "zzip"
      "nfs"
      "audiofile"
      "faad"
      "flac"
      "gme"
      "mpg123"
      "opus"
      "vorbis"
      "vorbisenc"
      "lame"
      "libsamplerate"
      "shout"
      "libmpdclient"
      "id3tag"
      "expat"
      "pcre"
      "sqlite"
      "qobuz"
      "alsa"
      "systemd"
      "syslog"
      "io_uring"
      "mad"
      "jack"
      "pipewire"
    ];
  };
}
