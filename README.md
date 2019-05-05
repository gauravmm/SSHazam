# SSHazam!

This tool speculatively opens SSH ControlMaster connections when you use `bash` autocomplete to fill in a server name. It saves you `<duration>` of annoyance every day!

## How it Works

When you type in an `ssh` command and auto-complete the server name, it examines your `~/.ssh/config` file and suggests completions. If only a few suggestions are presented, it opens a ControlMaster connection to these servers in the background; when you eventually select the correct server `ssh` automatically uses the ControlMaster connection, saving you precious `<duration>`,

It supports these types of commands to connect to server `yggdrasil`:

 - `ssh yg<tab>`
 - `ssh freyr@yg<tab>`
 - `ssh -o Option=Value ... yg<tab>`
 - `ssh -o Option=Value ... freyr@yg<tab>`

It does not support changing verbosity for connection debugging: `ssh -v`, `ssh -vvv`, etc. (ControlMaster client connections have the same verbosity as the master connection.)

## Requirements

This requires a reasonably modern version of `bash`. We recommend BASH 4.4.18 or later; this corresponds to the default shell on Ubuntu 16.04 and later. However, the default BASH 3.2 on OS X will usually work.

For OS X, the following steps must first be executed. (For Ubuntu, these are unnecessary.):
* Optional: Upgrade bash version via instructions [here](https://itnext.io/upgrading-bash-on-macos-7138bd1066ba).
* Install `flock` via instructions [here](https://github.com/discoteq/flock).
* Install `coreutils` via instructions [here](https://github.com/labbots/google-drive-upload/issues/12).

## Usage

To use this utility once, download the script and run `source ssh_autocomp.bash`. To install it, save it somewhere and add the `source` line to your `~/.bashrc` or `~/.bash_profile` or similar.

Configuration information is stored in the head of the file itself. You can set the following variables:

 - `SSH_CONFIG_PATHS`: a space-separated list of paths to search for `HOST` directives.
 - `MAX_CM_OPEN`: the maximum number of ControlMaster connections to open; if there are more than these many possible servers in your auto-complete then use a heuristic to decide which connections to open.
 - `HEURISTIC`: the heuristic to use to decide which connections to open; values are `""`, `"last"`, `"most"`
 - `HEURISTIC_CACHE_LNC`: cache file for `last` heuristic
 - `HEURISTIC_CACHE_MC`: cache file for `most` heuristic
 
Remember to run `source ssh_autocomp.bash` each time you change the file!

### Heuristics

 - `""`: If a blank heuristic is specified no automatic connections are made.
 - `"last"`: Open the `$MAX_CM_OPEN` servers most recently connected to; this heuristic updates its list of recently-connected servers every day or whenever any file in `SSH_CONFIG_PATHS` is updated.
 - `"most"`: Open the `$MAX_CM_OPEN` servers most often connected to; this heuristic updates its list of recently-connected servers every day or whenever any file in `SSH_CONFIG_PATHS` is updated.

### Debugging

In a separate terminal window, run `touch debug.log` and then run `tail -f debug.log` to see debug messages as they are generated.
