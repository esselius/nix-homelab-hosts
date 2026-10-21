# Host addressing inventory. The Taskfile resolves HOST to an address here so
# `task deploy HOST=rpi5-4gb` can never silently target the other board (the
# old independent HOST/IP defaults allowed exactly that).
{
  rpi5-8gb.ip = "192.168.50.80";
  rpi5-4gb.ip = "192.168.50.33";
}
