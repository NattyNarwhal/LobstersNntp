# LobstersNntp

This is an NNTP to Lobsters gateway. It's read-only, but seeing as the Lobsters
API is also read-only right now, that doesn't matter.

It's written in Elixir, using Mnesia to store cached messages.

The license is the same as Lobsters itself (3-clause BSD).

This was inspired by Tavis Ormandy's [nntpit](https://github.com/taviso/nntpit).
I had this idea for a while, but nntpit made it look realistic.

## Running

Make sure you have Elixir installed. As of right now, there is no configuration.
The server listens on port 1119. The client information doesn't matter, since
you can't post.

```
$ mix deps.get # get dependencies
$ iex -S mix # start application with REPL attached (compiles if needed)
# Unfortunately you need to manually stir the pot (no background job yet)
iex> LobstersNntp.LobstersClient.update_articles
```

## Tested clients

Fair warning: Most of the clients I tested are GUI ones. I suspect unlike a lot
of older TUI ones, they employ different techniques to fetch, and they probably
handle HTML news articles better.

* Outlook Express: works
* Mozilla (and likely modern Thunderbird): works
* Netscape 4: works, doesn't auto-detect UTF-8 messages
* Xnews: Message display erratic, doesn't support text/html (renders as plain)
* Internet News (from Internet Explorer 3): messages blank
* Agent: default text view shows 
* MicroPlanet Gravity: refuses to list the newsgroups

Feel free to try more!

## Known issues

* More DRY
* Should offer plain text; probably use MIME to staple them together
* Time zone, port, Lobsters instance should all be configurable
* Support non-XOVER commands for fetching headers

## How does this work?

There's a small server that handles talking to Lobsters. It can be told to go
out and fetch the 25 newest posts and their comments.

The data is backed by Mnesia, Erlang's built-in database.

However, we need another server is responsible for taking the data from Mnesia
and transforming them into something vaguely mbox-shaped for usenet. I've had a
few bugs, so having it in a separate GenServer from the NNTP client is handy!

Article numbering is per-group and annoying. To deal with this, we just have a
single group. The `lobsters` group encapsulates all stories and comments it
knows of. Stories have the "fake" newsgroups of `lobsters.tag.*` to represent
any tags.

Lobsters pre-converts Markdown to HTML on endpoints, so we just roll with
passing through HTML. This isn't ideal, however.

Most GUI NNTP clients have a flow of:

* Declare they're a client with `MODE READER`
* To get a list of group on request, use `LIST` or maybe `NEWGROUPS`
* NNTP is stateful, so select with `GROUP` (which also gets you post numbers)
* Use `XOVER` on a range of articles in the group, which gets most headers
  * These fall back to `XHDR` if they can't use `XOVER` (or  just `HEAD`)
* Use `ARTICLE` to select (it's stateful too!) and return headers and body

More could be involved with simplistic clients.
