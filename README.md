# bashtools — Interactive Cron & MongoDB Tools for the Terminal

**Schedule jobs. Choose backups. Restore databases. Stay in your terminal.**

bashtools is a collection of open-source Bash scripts for **cron job management,
MongoDB backup and restore, and server maintenance**. Interactive terminal menus
powered by `fzf` let you choose jobs, databases, and archives, then review the
operation before applying it.

Built for developers and system administrators who manage application servers
over SSH, keep development and production schedules in Git, and move MongoDB
backups between environments.

[Explore the tools](#explore-the-tools) · [Try a cron preview](#try-a-cron-preview) · [Cron guide](cron/README.md) · [MongoDB guide](mongo/README.md)

## Why bashtools?

- **Make routine server work easier to review.** Pick from named jobs and dated
  archives, see their states and sizes, and inspect cron changes before installing.
- **Keep schedules with your project.** Store development and production jobs in
  plain-text crontab files. Toggle jobs without losing their commands or comments.
- **Use familiar command-line tools.** The scripts work with `crontab`,
  `mongodump`, `mongorestore`, SSH, and rsync through keyboard-driven menus.
- **Choose one tool or the whole workflow.** Add a scheduled task, download a
  backup, or restore a database independently. Each script has a focused job.

## Explore the tools

The screenshots below show the actual Bash scripts and `fzf` running with demo
data. Full configuration and command-line options are in each directory's guide.

### cronsetup — Interactive cron job builder

Turn a command into a scheduled task with a six-step terminal wizard. Choose a
script, select a common schedule or enter a cron expression, configure logging,
and add a description. Preview the finished job before saving it to your dev or
production crontab file.

**Useful for:** scheduling database backups, cleanup scripts, reports, and other
recurring server tasks.

![Interactive Bash cron job builder showing schedule presets in the terminal](cron/screenshots/cronsetup.png)

[Create your first cron job →](cron/README.md#cronsetup--add-a-job)

### cronedit — Terminal crontab manager with on/off toggles

See which cron jobs are enabled and which are already installed. Mark jobs to
switch them on or off, review the diff, and confirm the installation. Saved
states persist between runs, and the final `crontab -l` output lets you verify
what is actually installed.

**Useful for:** reviewing schedule changes, pausing recurring jobs, and managing
separate development and production cron files.

![Terminal crontab manager with green on labels and selected jobs ready to toggle](cron/screenshots/cronedit.png)

[Manage cron jobs →](cron/README.md#cronedit--switch-jobs-on-and-off-and-install) · [See the review screen](cron/screenshots/cronedit-review.png)

### export.sh — MongoDB backup script for Docker

Select one or more MongoDB databases from a terminal list and create a separate,
compressed archive for each. The script runs `mongodump` inside your Docker
container and writes timestamped `.archive.gz` files to the host, with progress
and file-size output.

**Useful for:** creating database snapshots before maintenance and preparing
archives for a development environment.

![MongoDB Docker backup tool with multiple databases selected for mongodump](mongo/screenshots/export.png)

[Back up MongoDB databases →](mongo/README.md#exportsh--create-archives)

### backup-from-prod.sh — Download MongoDB backups over SSH

Browse existing production backup archives by date and size, select the files
you need, and download them with rsync over SSH. Choose individual archives in
the TUI or use `--all` to download every archive in the selected remote directory.

**Useful for:** fetching a recent database backup or choosing an older snapshot
for debugging.

![MongoDB backup download tool listing production archives with dates and sizes](mongo/screenshots/backup-from-prod.png)

[Download production backups →](mongo/README.md#backup-from-prodsh--download-archives)

### import.sh — MongoDB restore tool with three modes

Choose a MongoDB archive, target database, and restore strategy: replace the
whole database, replace the collections in the archive, or append without
dropping existing collections. Review the target and mode before confirming.
Restore under a different database name when you need a separate working copy.

**Useful for:** refreshing development data and restoring an application backup
to a chosen MongoDB database.

![Interactive MongoDB restore tool showing replace database, replace collections, and append modes](mongo/screenshots/import.png)

[Restore a MongoDB archive →](mongo/README.md#importsh--restore-an-archive) · [See the confirmation screen](mongo/screenshots/import-review.png)

## Try a cron preview

With Bash and `fzf` installed, clone the repository and explore the included
sample jobs. This command lets you pick state changes and preview the result
without installing a crontab or modifying the job file:

```bash
git clone https://github.com/frontdevops/bashtools.git
cd bashtools/cron
./cronedit dev --dry-run
```

For a preview without the interactive picker, use
`./cronedit dev --all --dry-run`. It shows all sample jobs as enabled.

## Setup and documentation

| Workflow | What you need | Guide |
| --- | --- | --- |
| Cron job scheduling and management | Bash 3.2+, `fzf` for menus, `crontab` for installation | [Cron setup and usage](cron/README.md) |
| MongoDB backup and restore | Bash, Docker, MongoDB tools in the container, connection settings, and `fzf` for menus; export requires Bash 4+ | [MongoDB configuration and usage](mongo/README.md) |
| Remote backup downloads | Bash, SSH, rsync, GNU `find` on the remote server, and `fzf` unless using `--all` | [Download options](mongo/README.md#backup-from-prodsh--download-archives) |

Cron installation replaces the current user's crontab with the selected
project's result. MongoDB restore modes can replace existing data. The guides
explain confirmation prompts, backup behavior, and each operation's scope.

## License

[MIT](LICENSE) — use, modify, and share the scripts under the MIT license.
