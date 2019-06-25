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
    uri = URI.parse(remote_path)
    filename = Path.basename(uri.path)

    case save_file(uri, filename) do
      {:ok, {local_path, mime_type}} ->
        %Arc.File{path: local_path, file_name: filename, mime_type: mime_type}

      :error ->
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
      true -> %Arc.File{path: path, file_name: filename, mime_type: MIME.from_path(path)}
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

  defp save_file(uri, filename) do
    local_path =
      generate_temporary_path()
      |> Kernel.<>(Path.extname(filename))

    case save_temp_file(local_path, uri) do
      {:ok, mime_type} -> {:ok, {local_path, mime_type}}
      _ -> :error
    end
  end

  defp save_temp_file(local_path, remote_path) do
    with {:ok, headers, response_ref} <- get_remote_path(remote_path),
         {:ok, body} <- get_body(response_ref),
         {:ok, mime_type} <- get_mime_type(headers),
         :ok <- File.write(local_path, body) do
      {:ok, mime_type}
    else
      error -> error
    end
  end

  # hakney :connect_timeout - timeout used when establishing a connection, in milliseconds
  # hakney :recv_timeout - timeout used when receiving from a connection, in milliseconds
  # poison :timeout - timeout to establish a connection, in milliseconds
  # :backoff_max - maximum backoff time, in milliseconds
  # :backoff_factor - a backoff factor to apply between attempts, in milliseconds
  defp get_remote_path(remote_path) do
    options = [
      follow_redirect: true,
      recv_timeout: Application.get_env(:arc, :recv_timeout, 5_000),
      connect_timeout: Application.get_env(:arc, :connect_timeout, 10_000),
      timeout: Application.get_env(:arc, :timeout, 10_000),
      max_retries: Application.get_env(:arc, :max_retries, 3),
      backoff_factor: Application.get_env(:arc, :backoff_factor, 1000),
      backoff_max: Application.get_env(:arc, :backoff_max, 30_000)
    ]

    request(remote_path, options)
  end

  defp request(remote_path, options, tries \\ 0) do
    case :hackney.get(URI.to_string(remote_path), [], "", options) do
      {:ok, 200, headers, client_ref} ->
        {:ok, headers, client_ref}

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

  defp get_mime_type(headers) do
    Enum.find(headers, fn
      {"Content-Type", _} -> true
      _ -> false
    end)
    |> case do
      {"Content-Type", value} ->
        [mime_type | _] = String.split(value, ";")
        {:ok, mime_type}

      nil ->
        MIME.from_path("")
    end
  end
end
