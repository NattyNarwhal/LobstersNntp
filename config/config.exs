import Config

# Change the $(env).exs file

config :lobsters_nntp,
  port: 119,
  domain: "lobste.rs",
  tz: "CST"

# Not yet
#import_config "#{config_env()}.exs"
import_config "#{Mix.env()}.exs"
