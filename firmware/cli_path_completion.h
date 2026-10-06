#ifndef CLI_PATH_COMPLETION_H
#define CLI_PATH_COMPLETION_H

#include "embedded_cli.h"

#define PATH_DISPLAY_MAX 40

/* Complete the first path argument of ls, mount, cart_load, tape_load or cd. */
void cli_path_complete(struct embedded_cli *cli);

/* Show the current directory, shortening only its displayed path. */
bool cli_directory_prompt_update(struct embedded_cli *cli);

#endif
