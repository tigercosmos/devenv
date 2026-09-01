package agent

// sockaddr_un.sun_path has 104 bytes on Darwin, including the trailing NUL.
const maxUnixSocketPath = 103
