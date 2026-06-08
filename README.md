# get_git
A little bash script to backup git repos from one remote to another.

## How to use
Simply run (one off):
```
bash ./get_git.sh "originalRepo.git" "tmp/path/" "backupRepo.git"
```

Or add it to a crontab.

## Requirements
* git (naturally)

* For a crontab this does require a keychain utility [example here](https://www.cyberciti.biz/faq/ubuntu-debian-linux-server-install-keychain-apt-get-command/)