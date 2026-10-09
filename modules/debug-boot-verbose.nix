{ ... }:
{
  # Verbose boot console logging - added during the root-wipe boot-hang
  # investigation to see further into initrd than the default log level
  # allowed. Harmless to keep permanently: genuinely useful if boot issues
  # ever need debugging again. Main hosts only (not the bootstrap
  # installer, which never showed the hang in the first place).
  boot.consoleLogLevel = 8;
  boot.kernelParams = [ "ignore_loglevel" ];
}
