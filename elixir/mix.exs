defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Config,
          SymphonyElixir.DispatchLifecycle,
          SymphonyElixir.Dispatch.Retry,
          SymphonyElixir.Dispatch.Scheduler,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.Linear.Issue,
          SymphonyElixir.StateSync.GitHub.Adapter,
          SymphonyElixir.StateSync.GitHub.MergeAutomation.AutoMerge,
          SymphonyElixir.StateSync.GitHub.MergeAutomation.PRFeedback,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.Linear.Adapter,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.StateSync.Local.Adapter,
          SymphonyElixir.StateSync.Local.Issue,
          SymphonyElixir.StateSync.Local.ProjectConfig,
          SymphonyElixir.StateSync.Local.Workflow,
          SymphonyElixir.PromptBuilder,
          SymphonyElixir.PromptEngine.Continuation,
          SymphonyElixir.PromptEngine.Renderer,
          SymphonyElixir.RuntimeConfig,
          SymphonyElixir.RuntimeConfigFile,
          SymphonyElixir.RuntimeConfigStore,
          SymphonyElixir.RuntimeFile,
          SymphonyElixir.RuntimeSource,
          SymphonyElixir.RuntimeSourceStore,
          SymphonyElixir.StateSync,
          SymphonyElixir.StateSync.Issue,
          SymphonyElixir.StateSync.Memory,
          SymphonyElixir.SessionTracker.Metering,
          SymphonyElixir.SessionTracker.Persistence,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.Workspace,
          SymphonyElixir.Workspace.Hooks,
          SymphonyElixir.Workspace.Provisioner,
          SymphonyElixir.Workspace.Provisioner.PathSafety,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        plt_local_path: Path.expand(".dialyzer", __DIR__),
        plt_core_path: Path.expand(".dialyzer", __DIR__)
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp elixirc_paths(:test) do
    base_elixirc_paths() ++
      [
        "test/support",
        external_elixir_path("../state-sync/test/lib"),
        external_elixir_path("../state-sync-github/test/lib"),
        external_elixir_path("../state-sync-local/test/lib")
      ]
  end

  defp elixirc_paths(_env), do: base_elixirc_paths()

  defp base_elixirc_paths do
    [
      "lib",
      external_elixir_path("../workflow-engine/interpreter/lib"),
      external_elixir_path("../workflow-engine/mermaid-parser/lib"),
      external_elixir_path("../workflow-engine/validate/lib"),
      external_elixir_path("../workflow-engine/test/lib"),
      external_elixir_path("../workspace/provisioner/lib"),
      external_elixir_path("../workspace/hooks/lib"),
      external_elixir_path("../prompt-engine/renderer/lib"),
      external_elixir_path("../prompt-engine/continuation/lib"),
      external_elixir_path("../state-sync/interface/lib"),
      external_elixir_path("../state-sync-github/adapter/lib"),
      external_elixir_path("../state-sync-github/merge-automation/lib"),
      external_elixir_path("../state-sync-local/adapter/lib")
    ]
  end

  defp external_elixir_path(relative_path) when is_binary(relative_path) do
    Path.expand(relative_path, __DIR__)
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "siaan",
      path: "bin/siaan"
    ]
  end
end
