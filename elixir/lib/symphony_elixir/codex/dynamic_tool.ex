defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @github_graphql_tool "github_graphql"

  @graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    supported_tools = supported_tool_names(opts)

    case tool do
      @linear_graphql_tool ->
        if @linear_graphql_tool in supported_tools do
          linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
          execute_graphql(arguments, linear_client, @linear_graphql_tool)
        else
          unsupported_tool_response(tool, supported_tools)
        end

      @github_graphql_tool ->
        if @github_graphql_tool in supported_tools do
          github_client = Keyword.get(opts, :github_client, &GitHubClient.graphql/3)
          execute_graphql(arguments, github_client, @github_graphql_tool)
        else
          unsupported_tool_response(tool, supported_tools)
        end

      other ->
        unsupported_tool_response(other, supported_tools)
    end
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    case tracker_kind(opts) do
      "linear" -> [linear_tool_spec()]
      "github" -> [github_tool_spec()]
      "memory" -> []
      nil -> [linear_tool_spec(), github_tool_spec()]
      _ -> []
    end
  end

  defp execute_graphql(arguments, client_fun, tool_name) when is_function(client_fun, 3) do
    with {:ok, query, variables} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- client_fun.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(tool_name, reason))
    end
  end

  defp normalize_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} -> {:ok, query, variables}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(tool_name, :missing_query) do
    %{
      "error" => %{
        "message" => "`#{tool_name}` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(tool_name, :invalid_arguments) do
    %{
      "error" => %{
        "message" => "`#{tool_name}` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(tool_name, :invalid_variables) do
    %{
      "error" => %{
        "message" => "`#{tool_name}.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(@linear_graphql_tool, :missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload(@linear_graphql_tool, {:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload(@linear_graphql_tool, {:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(@github_graphql_tool, :missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload(@github_graphql_tool, {:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload(@github_graphql_tool, {:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(@linear_graphql_tool, reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(@github_graphql_tool, reason) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp linear_tool_spec do
    %{
      "name" => @linear_graphql_tool,
      "description" => "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
      "inputSchema" => @graphql_input_schema
    }
  end

  defp github_tool_spec do
    %{
      "name" => @github_graphql_tool,
      "description" => "Execute a raw GraphQL query or mutation against GitHub using Symphony's configured auth.",
      "inputSchema" => @graphql_input_schema
    }
  end

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(opts), & &1["name"])
  end

  defp tracker_kind(opts) when is_list(opts) do
    case Keyword.get(opts, :tracker_kind) do
      kind when is_binary(kind) ->
        normalize_tracker_kind(kind)

      kind when is_atom(kind) and not is_nil(kind) ->
        kind |> Atom.to_string() |> normalize_tracker_kind()

      _ ->
        nil
    end
  end

  defp normalize_tracker_kind(kind) when is_binary(kind), do: kind |> String.trim() |> String.downcase()

  defp unsupported_tool_response(tool_name, supported_tools) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool_name)}.",
        "supportedTools" => supported_tools
      }
    })
  end
end
