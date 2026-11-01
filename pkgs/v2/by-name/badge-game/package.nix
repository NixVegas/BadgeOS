# badge-game COMMAND [ARGS...]: puts the HDMI output back in the desktop mode however
# the game ends, crash or kill included.
{
  lib,
  writeShellApplication,
  coreutils,
  # For swaymsg. The badge passes its session's sway, config.programs.sway.package.
  sway,
  # The mode the output goes back to: badge.graphics.outputMode.
  outputMode ? "1280x720",
}:
writeShellApplication {
  name = "badge-game";

  runtimeInputs = [
    coreutils
    sway
  ];

  runtimeEnv = {
    BADGE_OUTPUT_MODE = outputMode;
  };

  text = builtins.readFile ./badge-game.sh;

  # restore and stop only run from traps, which shellcheck does not follow.
  excludeShellChecks = [ "SC2329" ];

  meta = {
    description = "Runs a game and restores the desktop output mode when it exits";
    mainProgram = "badge-game";
    platforms = lib.platforms.linux;
  };
}
