package agent

// sockaddr_un.sun_path has 108 bytes on Linux, including the trailing NUL.
const maxUnixSocketPath = 107
