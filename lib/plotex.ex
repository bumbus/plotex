defmodule Plotex do
  alias Plotex.ViewRange
  alias Plotex.Axis
  alias Plotex.Output.Formatter
  require Logger

  @moduledoc """
  Documentation for Plotex.

  TODO
  """
  defstruct [:config, :xticks, :yticks, :datasets]

  @type data_types :: number | DateTime.t() | NaiveDateTime.t()
  @type data_item :: Stream.t(data_types) | Enum.t(data_types)
  @type data_pair :: {data_item, data_item}
  @type data :: Stream.t(data_pair) | Enum.t(data_pair)

  @type t :: %Plotex{
          config: Plotex.Config.t(),
          xticks: Enumerable.t(),
          yticks: Enumerable.t(),
          datasets: Enumerable.t()
        }

  @doc """
  Generates a stream of the data points (ticks) for a given axis.
  """
  def generate_axis(%Axis{units: units} = axis) do
    unless axis.limits.start == nil || axis.limits.stop == nil do
      %{data: data, basis: basis} = Plotex.Axis.Units.scale(units, axis.limits)
      # Logger.warn("TIME generate_axis: #{inspect(data |> Enum.to_list)}")
      # Logger.warn("TIME generate_axis: limits: #{inspect(axis.limits)}")
      # Logger.warn("TIME generate_axis: view: #{inspect(axis.view)}")
      trng = scale_data(data, axis)

      # Logger.warn("TIME generate_axis: trng: #{inspect(trng |> Enum.to_list)}")
      # Logger.warn("TIME generate_axis: range: #{inspect(axis.view)}")

      ticks =
        Stream.zip(data, trng)
        # |> Stream.each(& Logger.warn("dt gen view: #{inspect &1}"))
        |> Stream.filter(&(elem(&1, 1) >= axis.view.start))
        |> Stream.filter(&(elem(&1, 1) <= axis.view.stop))
        |> Enum.to_list()

      [data: ticks, basis: basis]
    else
      [data: [], basis: nil]
    end
  end

  @doc """
  Returns a stream of scaled data points zipped with the original points.
  """
  def scale_data(_data, %Axis{limits: %{start: start, stop: stop}} = _axis)
      when is_nil(start) or is_nil(stop),
      do: []

  def scale_data(data, %Axis{} = axis) do
    # Logger.warn("SCALE_DATA: #{inspect axis}")
    m =
      ViewRange.diff(axis.view.stop, axis.view.start) /
        ViewRange.diff(axis.limits.stop, axis.limits.start)

    b = axis.view.start |> ViewRange.to_val()
    x! = axis.limits.start |> ViewRange.to_val()

    data
    |> Stream.map(fn x -> m * (ViewRange.to_val(x) - x!) + b end)
  end

  @doc """
  Returns of scaled data for both X & Y coordinates for a given {X,Y} dataset.
  """
  def plot_data({xdata, ydata}, %Axis{} = xaxis, %Axis{} = yaxis) do
    xrng = scale_data(xdata, xaxis)
    yrng = scale_data(ydata, yaxis)

    {Enum.zip(xdata, xrng), Enum.zip(ydata, yrng)}
  end

  @doc """
  Find the appropriate limits given an enumerable of datasets.

  For example, given {[1,2,3,4], [0.4,0.3,0.2,0.1]} will find the X limits 1..4
  and the Y limits of 0.1..0.4.
  """
  def limits(datasets, opts \\ []) do
    # Logger.warn("LIMITS: #{inspect opts} ")
    proj = Keyword.get(opts, :projection, :cartesian)
    min_xrange = get_in(opts, [:xaxis, :view_min]) || ViewRange.empty()
    min_yrange = get_in(opts, [:yaxis, :view_min]) || ViewRange.empty()

    {xl, yl} =
      for {xdata, ydata} <- datasets, reduce: {min_xrange, min_yrange} do
        {xlims, ylims} ->
          xlims! = xdata |> ViewRange.from(proj)
          ylims! = ydata |> ViewRange.from(proj)

          xlims! = ViewRange.min_max(xlims, xlims!)
          ylims! = ViewRange.min_max(ylims, ylims!)

          {xlims!, ylims!}
      end

    xl = ViewRange.pad(xl, opts[:xaxis] || [])
    yl = ViewRange.pad(yl, opts[:yaxis] || [])

    # Logger.warn("lims reduced: limits!: post!: #{inspect {xl, yl}}")
    {xl, yl}
  end

  def std_units(opts) do
    case opts[:kind] do
      nil -> nil
      :numeric -> %Axis.Units.Numeric{}
      :datetime -> %Axis.Units.Time{}
    end
  end

  def std_fmt(opts) do
    case opts[:kind] do
      nil -> %Plotex.Output.Formatter.NumericDefault{}
      :numeric -> %Plotex.Output.Formatter.NumericDefault{}
      :datetime -> %Plotex.Output.Formatter.DateTime.Calendar{}
    end
  end

  @doc """
  Create a Plotex struct for given datasets and configuration. Will load and scan data
  for all input datasets.
  """
  @spec plot(Plotex.data(), Keyword.t()) :: Plotex.t()
  def plot(datasets, opts \\ []) do
    {xlim, ylim} = limits(datasets, opts)

    # ticks = opts[:xaxis][:ticks]

    # And this part is kludgy...
    xaxis = %Axis{
      limits: xlim,
      units: struct(opts[:xaxis][:units] || std_units(opts[:xaxis]) || %Axis.Units.Numeric{}),
      formatter:
        struct(opts[:xaxis][:formatter] || std_fmt(opts[:xaxis]) || %Formatter.NumericDefault{}),
      view: %ViewRange{start: 10, stop: (opts[:xaxis][:width] || 100) - 10}
    }

    yaxis = %Axis{
      limits: ylim,
      units: struct(opts[:yaxis][:units] || std_units(opts[:yaxis]) || %Axis.Units.Numeric{}),
      formatter:
        struct(
          opts[:yaxis][:formatter] || std_fmt(opts[:yaxis]) || %Formatter.DateTime.Calendar{}
        ),
      view: %ViewRange{start: 10, stop: (opts[:yaxis][:width] || 100) - 10}
    }

    [data: xticks, basis: xbasis] = generate_axis(xaxis)

    [data: yticks, basis: ybasis] = generate_axis(yaxis)

    xaxis = xaxis |> Map.put(:basis, xbasis)
    yaxis = yaxis |> Map.put(:basis, ybasis)

    # Logger.warn("plot xaxis: #{inspect xaxis}")
    # Logger.warn("plot yaxis: #{inspect yaxis}")

    config = %Plotex.Config{
      xaxis: xaxis,
      yaxis: yaxis
    }

    # Logger.warn("xticks: #{inspect xticks  |> Enum.to_list()}")
    # Logger.warn("yticks: #{inspect yticks  |> Enum.to_list()}")

    datasets! =
      for {data, idx} <- datasets |> Stream.with_index(), into: [] do
        {xd, yd} = Plotex.plot_data(data, config.xaxis, config.yaxis)
        {Stream.zip(xd, yd), idx}
      end

    # Logger.warn  "datasets! => #{inspect datasets! |> Enum.at(0) |> elem(0) |> Enum.to_list()}"

    %Plotex{config: config, xticks: xticks, yticks: yticks, datasets: datasets!}
  end
end
