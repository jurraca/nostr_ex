defmodule NostrEx.Query.Result do
  @moduledoc """
  Outcome of a bounded query (`NostrEx.query/2`).
  """

  alias NostrEx.Client
  alias NostrCore.Event

  @type completion :: :eose | :timeout | :max_events

  @type t :: %__MODULE__{
          sub_id: String.t(),
          events: [Event.t()],
          eose_from: [String.t()],
          closed_by: [{String.t(), String.t() | nil}],
          completion: completion(),
          failures: [Client.failure()]
        }

  defstruct sub_id: nil,
            events: [],
            eose_from: [],
            closed_by: [],
            completion: nil,
            failures: []

  @doc """
  True when every relay that received the REQ answered with EOSE before the
  timeout or event cap.
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{completion: :eose}), do: true
  def complete?(%__MODULE__{}), do: false
end

