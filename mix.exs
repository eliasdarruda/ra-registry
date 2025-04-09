defmodule RaRegistry.MixProject do
  use Mix.Project

  def project do
    [
      app: :ra_registry,
      version: "0.1.1",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/eliasdarruda/ra-registry"
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ra, "~> 2.7"},
      {:ex_doc, "~> 0.29", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A distributed registry for Elixir GenServers using Ra (RabbitMQ's Raft implementation)"
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/eliasdarruda/ra-registry"},
      maintainers: ["eliasdarruda"]
    ]
  end
end
