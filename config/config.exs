import Config

config :sorrel,
  user_agent: [{:system, "SORREL_USER_AGENT"}, "sorrel/#{Mix.Project.config()[:version]}"],
  connect_timeout: [{:system, "SORREL_CONNECT_TIMEOUT"}, 10_000],
  receive_timeout: [{:system, "SORREL_RECEIVE_TIMEOUT"}, 15_000],
  pool_size: [{:system, "SORREL_POOL_SIZE"}, 10],
  pool_timeout: [{:system, "SORREL_POOL_TIMEOUT"}, 5_000],
  conn_max_idle_time: [{:system, "SORREL_CONN_MAX_IDLE_TIME"}, 30_000],
  accept_timeout: [{:system, "SORREL_SSH_ACCEPT_TIMEOUT"}, 5_000],
  channel_open_timeout: [{:system, "SORREL_SSH_CHANNEL_OPEN_TIMEOUT"}, 10_000],
  ssh_connect_timeout: [{:system, "SORREL_SSH_CONNECT_TIMEOUT"}, 10_000],
  ssh_auth: [:agent, :identity, :password],
  ssh_verify: :verify_peer
