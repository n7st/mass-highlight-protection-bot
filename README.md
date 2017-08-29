# Mass Highlight Protection Bot

An IRC bot which bans for mass highlighting in a channel.

## Installation

* Clone the repository.
* Inside the directory, run `dzil listdeps | cpanm`.

## Usage

* Please note that the bot will only start performing bans after the post-join
  channel sync has occurred. This is due to information required before the bot
  can begin to monitor the channel (nickname list).
* Copy the example configuration file (`data/config.yaml.example`) to
  `data/config.yaml` and edit it with your own connection details.
* Run the bot with `perl script/masshl.pl`.

