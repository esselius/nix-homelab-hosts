{ lib }:
let
  mod = a: b: a - (a / b) * b;

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (lib.range 1 n);

  ipv4ToInt =
    ip: builtins.foldl' (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." ip);

  intToIpv4 =
    n:
    lib.concatStringsSep "." (
      map toString [
        (n / 16777216)
        (mod (n / 65536) 256)
        (mod (n / 256) 256)
        (mod n 256)
      ]
    );
in
{
  # Network address of an IPv4 CIDR, in CIDR form: "10.43.1.1/24" -> "10.43.1.0/24".
  # Used to derive a bridge's subnet from the address it is assigned, so the two
  # can never disagree (a mismatch silently breaks masquerade rules).
  cidrToNetwork =
    cidr:
    let
      m = builtins.match "([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)/([0-9]+)" cidr;
    in
    if m == null then
      throw "cidrToNetwork: expected an IPv4 CIDR (a.b.c.d/prefix), got '${cidr}'"
    else
      let
        prefix = lib.toInt (builtins.elemAt m 1);
        ip = ipv4ToInt (builtins.elemAt m 0);
      in
      if prefix > 32 then
        throw "cidrToNetwork: prefix /${toString prefix} out of range in '${cidr}'"
      else
        "${intToIpv4 (ip - mod ip (pow2 (32 - prefix)))}/${toString prefix}";

  # A systemd oneshot + timer that refreshes a node_exporter textfile.
  # The result is a module; merge it with `imports = [ (mkTextfileCollector {...}) ];`.
  mkTextfileCollector =
    {
      name,
      description,
      script,
      onBootSec,
      interval,
      path ? [ ],
    }:
    {
      systemd.services.${name} = {
        inherit description path;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = script;
        };
      };

      systemd.timers.${name} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          inherit onBootSec;
          OnUnitActiveSec = interval;
        };
      };
    };
}
