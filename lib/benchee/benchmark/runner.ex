defmodule Benchee.Benchmark.Runner do
  @moduledoc """
  This module actually runs our benchmark scenarios, adding information about
  run time and memory usage to each scenario.
  """

  alias Benchee.Benchmark
  alias Benchee.Benchmark.{Scenario, ScenarioContext}
  alias Benchee.Utility.{RepeatN, Parallel}
  alias Benchee.Configuration

  @doc """
  Executes the benchmarks defined before by first running the defined functions
  for `warmup` time without gathering results and them running them for `time`
  gathering their run times.

  This means the total run time of a single benchmarking scenario is warmup +
  time.

  Warmup is usually important for run times with JIT but it seems to have some
  effect on the BEAM as well.

  There will be `parallel` processes spawned executing the benchmark job in
  parallel.
  """
  @spec run_scenarios([Scenario.t], ScenarioContext.t) :: [Scenario.t]
  def run_scenarios(scenarios, scenario_context) do
    %ScenarioContext{printer: printer, config: config} = scenario_context

    Enum.map(scenarios, fn scenario ->
      %Scenario{job_name: job_name, input_name: input_name} = scenario
      printer.benchmarking(job_name, input_name, config)
      run_scenario(scenario, scenario_context)
    end)
  end

  defp run_scenario(scenario, scenario_context) do
    scenario_input = run_before_scenario(scenario, scenario_context)
    scenario_context =
      %ScenarioContext{scenario_context | scenario_input: scenario_input}
    _ = run_warmup(scenario, scenario_context)
    measurements = run_benchmark(scenario, scenario_context)
    run_after_scenario(scenario, scenario_context)
    measurements
  end

  defp run_before_scenario(%Scenario{
                             before_scenario: local_before_scenario,
                             input: input
                           },
                           %ScenarioContext{
                             config: %{before_scenario: global_before_scenario}
                           }) do
    input
    |> run_before_function(global_before_scenario)
    |> run_before_function(local_before_scenario)
  end

  defp run_before_function(input, function) do
    if function do
      function.(input)
    else
      input
    end
  end

  defp run_warmup(scenario, scenario_context = %ScenarioContext{
                   config: %Configuration{warmup: warmup}
                 }) do
    measure_runtimes(scenario, scenario_context, warmup, false)
  end

  defp run_benchmark(scenario, scenario_context = %ScenarioContext{
                      config: %Configuration{
                        time: run_time,
                        print: %{fast_warning: fast_warning}
                      }
                    }) do
    measure_runtimes(scenario, scenario_context, run_time, fast_warning)
  end

  defp run_after_scenario(%{
                            after_scenario: local_after_scenario
                          },
                          %{
                            config: %{after_scenario: global_after_scenario},
                            scenario_input: input
                          }) do
    if local_after_scenario,  do: local_after_scenario.(input)
    if global_after_scenario, do: global_after_scenario.(input)
  end

  defp measure_runtimes(scenario, context, run_time, fast_warning)
  defp measure_runtimes(scenario, _, 0, _), do: scenario
  defp measure_runtimes(scenario, scenario_context, run_time, fast_warning) do
    end_time = current_time() + run_time
    :erlang.garbage_collect
    {num_iterations, initial_run_time} =
      determine_n_times(scenario, scenario_context, fast_warning)
    new_context =
      %ScenarioContext{scenario_context |
        current_time: current_time(),
        end_time: end_time,
        num_iterations: num_iterations
      }

    updated_scenario = %Scenario{scenario | run_times: [initial_run_time]}
    do_benchmark(updated_scenario, new_context)
  end

  defp current_time, do: :erlang.system_time :micro_seconds

  # If a function executes way too fast measurements are too unreliable and
  # with too high variance. Therefore determine an n how often it should be
  # executed in the measurement cycle.
  @minimum_execution_time 10
  @times_multiplier 10
  defp determine_n_times(scenario, scenario_context = %ScenarioContext{
                           num_iterations: num_iterations,
                           printer: printer
                         }, fast_warning) do
    {run_time, _} = measure_iteration(scenario, scenario_context)
    if run_time >= @minimum_execution_time do
      {num_iterations, run_time / num_iterations}
    else
      if fast_warning, do: printer.fast_warning()
      new_context = %ScenarioContext{scenario_context |
        num_iterations: num_iterations * @times_multiplier
      }
      determine_n_times(scenario, new_context, false)
    end
  end

  defp do_benchmark(scenario = %Scenario{run_times: run_times},
                    %ScenarioContext{
                      current_time: current_time, end_time: end_time
                    }) when current_time > end_time do
    # restore correct order - important for graphing
    %Scenario{scenario | run_times: run_times |> List.flatten |> Enum.sort}
  end
  defp do_benchmark(scenario = %Scenario{run_times: run_times,
                                         memory_usages: memory_usages},
                    scenario_context) do
    scenario_results =
      Parallel.map(0..scenario_context.config.parallel, fn _ ->
        iteration_time(scenario, scenario_context)
      end)
    new_run_times =
      Enum.map(scenario_results, fn {run_times, _} -> run_times end)
    new_memory_usages =
      Enum.map(scenario_results, fn {_, memory_usages} -> memory_usages end)
    updated_scenario =
      %Scenario{scenario | run_times: new_run_times ++ run_times,
                           memory_usages: new_memory_usages ++ memory_usages}
    updated_context =
      %ScenarioContext{scenario_context | current_time: current_time()}
    do_benchmark(updated_scenario, updated_context)
  end

  defp iteration_time(scenario, scenario_context = %ScenarioContext{
                                  num_iterations: num_iterations
                                }) do
    {microseconds, memory_usage} = measure_iteration(scenario, scenario_context)
    {microseconds / num_iterations, memory_usage / num_iterations}
  end

  defp measure_iteration(scenario = %Scenario{function: function},
                         scenario_context = %ScenarioContext{
                           num_iterations: 1
                         }) do
    new_input = run_before_each(scenario, scenario_context)
    {:memory, memory_usage_before} = :erlang.process_info(self(), :memory)
    {microseconds, return_value} = :timer.tc main_function(function, new_input)
    {:memory, memory_usage_after} = :erlang.process_info(self(), :memory)
    run_after_each(return_value, scenario, scenario_context)
    {microseconds, memory_usage_after - memory_usage_before}
  end
  defp measure_iteration(scenario, scenario_context = %ScenarioContext{
                          num_iterations: iterations,
                        }) when iterations > 1 do
    # When we have more than one iteration, then the repetition and calling
    # of hooks is already included in the function, for reference/reasoning see
    # `build_benchmarking_function/2`
    function = build_benchmarking_function(scenario, scenario_context)
    {:memory, memory_usage_before} = :erlang.process_info(self(), :memory)
    {microseconds, _return_value} = :timer.tc function
    {:memory, memory_usage_after} = :erlang.process_info(self(), :memory)
    {microseconds, memory_usage_after - memory_usage_before}
  end

  @no_input Benchmark.no_input()
  defp main_function(function, @no_input), do: function
  defp main_function(function, input),     do: fn -> function.(input) end

  # Builds the appropriate function to benchmark. Takes into account the
  # combinations of the following cases:
  #
  # * an input is specified - creates a 0-argument function calling the original
  #   function with that input
  # * number of iterations - when there's more than one iteration we repeat the
  #   benchmarking function during execution and measure the the total run time.
  #   We only run multiple iterations if a function is so fast that we can't
  #   accurately measure it in one go. Hence, we can't split up the function
  #   execution and hooks anymore and sadly we also measure the time of the
  #   hooks.
  defp build_benchmarking_function(
         %Scenario{
           function: function, before_each: nil, after_each: nil
         },
         %ScenarioContext{
           num_iterations: iterations,
           scenario_input: input,
           config: %{after_each: nil, before_each: nil}
         })
         when iterations > 1 do
    main = main_function(function, input)
    # with no before/after each we can safely omit them and don't get the hit
    # on run time measurements (See PR discussions for this for more info #127)
    fn -> RepeatN.repeat_n(main, iterations) end
  end
  defp build_benchmarking_function(
         scenario = %Scenario{function: function},
         scenario_context = %ScenarioContext{num_iterations: iterations})
         when iterations > 1 do
    fn ->
      RepeatN.repeat_n(
        fn ->
          new_input = run_before_each(scenario, scenario_context)
          main = main_function(function, new_input)
          return_value = main.()
          run_after_each(return_value, scenario, scenario_context)
        end,
        iterations
      )
    end
  end

  defp run_before_each(%{
                         before_each: local_before_each
                       },
                       %{
                         config: %{before_each: global_before_each},
                         scenario_input: input
                       }) do
    input
    |> run_before_function(global_before_each)
    |> run_before_function(local_before_each)
  end

  defp run_after_each(return_value,
                      %{
                        after_each: local_after_each
                      },
                      %{
                        config: %{after_each: global_after_each}
                      }) do
    if local_after_each,  do: local_after_each.(return_value)
    if global_after_each, do: global_after_each.(return_value)
  end
end
