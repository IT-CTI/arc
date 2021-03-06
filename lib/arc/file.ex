defmodule Arc.File do
  defstruct [:path, :file_name, :binary, :mime_type]

  def generate_temporary_path(file \\ nil) do
    extension = Path.extname((file && file.path) || "")

    file_name =
      :crypto.strong_rand_bytes(20)
      |> Base.encode32()
      |> Kernel.<>(extension)

    Path.join(System.tmp_dir(), file_name)
  end

  # Given a remote file
  def new(remote_path = "http" <> _) do
    case save_file(remote_path) do
      {:ok, {local_path, filename, mime_type}} ->
        %Arc.File{path: local_path, file_name: filename, mime_type: mime_type}

      _error ->
        {:error, :invalid_file_path}
    end
  end

  # Accepts a path
  def new(path) when is_binary(path) do
    case File.exists?(path) do
      true ->
        %Arc.File{path: path, file_name: Path.basename(path), mime_type: MIME.from_path(path)}

      false ->
        {:error, :invalid_file_path}
    end
  end

  def new(%{filename: filename, binary: binary}) do
    %Arc.File{
      binary: binary,
      file_name: Path.basename(filename),
      mime_type: MIME.from_path(filename)
    }
  end

  # Accepts a map conforming to %Plug.Upload{} syntax
  def new(%{filename: filename, path: path}) do
    case File.exists?(path) do
      true -> %Arc.File{path: path, file_name: filename, mime_type: MIME.from_path(filename)}
      false -> {:error, :invalid_file_path}
    end
  end

  def ensure_path(file = %{path: path}) when is_binary(path), do: file
  def ensure_path(file = %{binary: binary}) when is_binary(binary), do: write_binary(file)

  defp write_binary(file) do
    path = generate_temporary_path(file)
    :ok = File.write!(path, file.binary)

    %__MODULE__{
      file_name: file.file_name,
      path: path
    }
  end

  defp save_file(remote_path) do
    with {:ok, target_path, response_ref} <- get_remote_path(remote_path),
         {:ok, body} <- get_body(response_ref),
         {:ok, mime_type} <- get_mime_type(target_path),
         {:ok, local_path, filename} <- save_temp_file(target_path, body) do
      {:ok, {local_path, filename, mime_type}}
    end
  end

  defp save_temp_file(remote_path, body) do
    %{path: path} = URI.parse(remote_path)
    original_filename = Path.basename(path)
    local_path = generate_temporary_path() <> Path.extname(original_filename)

    with :ok <- File.write(local_path, body), do: {:ok, local_path, original_filename}
  end

  # hakney :connect_timeout - timeout used when establishing a connection, in milliseconds
  # hakney :recv_timeout - timeout used when receiving from a connection, in milliseconds
  # poison :timeout - timeout to establish a connection, in milliseconds
  # :backoff_max - maximum backoff time, in milliseconds
  # :backoff_factor - a backoff factor to apply between attempts, in milliseconds
  defp get_remote_path(remote_path) do
    options = [
      follow_redirect: false,
      recv_timeout: Application.get_env(:arc, :recv_timeout, 5_000),
      connect_timeout: Application.get_env(:arc, :connect_timeout, 10_000),
      timeout: Application.get_env(:arc, :timeout, 10_000),
      max_retries: Application.get_env(:arc, :max_retries, 3),
      backoff_factor: Application.get_env(:arc, :backoff_factor, 1000),
      backoff_max: Application.get_env(:arc, :backoff_max, 30_000),
      proxy: Application.get_env(:arc, :proxy, {}),
      pool: false
    ]

    request(remote_path, options)
  end

  defp request(remote_path, options, tries \\ 0) do
    case :hackney.get(remote_path, [], "", options) do
      {:ok, 302, _headers, client_ref} ->
        :hackney.location(client_ref)
        |> request(options, tries)

      {:ok, 200, headers, client_ref} ->
        case refresh_redirect(headers) do
          false -> {:ok, remote_path, client_ref}
          remote_path -> request(remote_path, options, tries)
        end

      {:error, %{reason: :timeout}} ->
        case retry(tries, options) do
          {:ok, :retry} -> request(remote_path, options, tries + 1)
          {:error, :out_of_tries} -> {:error, :timeout}
        end

      _ ->
        {:error, :arc_httpoison_error}
    end
  end

  defp retry(tries, options) do
    cond do
      tries < options[:max_retries] ->
        backoff = round(options[:backoff_factor] * :math.pow(2, tries - 1))
        backoff = :erlang.min(backoff, options[:backoff_max])
        :timer.sleep(backoff)
        {:ok, :retry}

      true ->
        {:error, :out_of_tries}
    end
  end

  defp get_body(response_ref), do: :hackney.body(response_ref)

  defp get_mime_type(remote_path) do
    %{path: path} = URI.parse(remote_path)
    {:ok, MIME.from_path(to_string(path))}
  end

  defp refresh_redirect(headers) do
    headers = :hackney_headers_new.from_list(headers)

    case :hackney_headers_new.get_value("refresh", headers) do
      :undefined -> false
      value -> String.split(value, "=", parts: 2) |> List.last()
    end
  end
end
