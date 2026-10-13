# frozen_string_literal: true

require "helper"
require "models/person"
require "jobs/kwargs_job"
require "active_support/core_ext/hash/indifferent_access"

class ImmutableArgumentsTest < ActiveSupport::TestCase
  class MutatingRetryJob < ActiveJob::Base
    def perform(data)
      JobBuffer.add(data.deep_dup)
      data[:mutated] = true
      retry_job if executions < 3
    end
  end

  class ArgumentsMutationRetryJob < ActiveJob::Base
    def perform(data)
      JobBuffer.add(data.deep_dup)
      data[:from_perform] = true
      arguments[0][:from_arguments] = true
      retry_job if executions < 2
    end
  end

  class NestedMutationRetryJob < ActiveJob::Base
    def perform(data, options:)
      JobBuffer.add([data.deep_dup, options.deep_dup, data.class])
      data[:list] << 3
      data[:name] << "!"
      data[:nested][:count] += 1
      options[:mode] = "mutated"
      retry_job if executions < 2
    end
  end

  class GlobalIDIdentityJob < ActiveJob::Base
    def perform(person)
      JobBuffer.add(person)
    end
  end

  setup do
    @original_immutable_arguments = ActiveJob.immutable_arguments
  end

  teardown do
    ActiveJob.immutable_arguments = @original_immutable_arguments
  end

  test "immutable_arguments defaults to false" do
    assert_equal false, ActiveJob.immutable_arguments
  end

  if adapter_is?(:inline, :test)
    test "retries reuse mutated arguments when immutable_arguments is disabled" do
      ActiveJob.immutable_arguments = false

      MutatingRetryJob.perform_later({ original: "value" })

      assert_equal [
        { original: "value" },
        { original: "value", mutated: true },
        { original: "value", mutated: true }
      ], JobBuffer.values
    end

    test "retries preserve original arguments when immutable_arguments is enabled" do
      ActiveJob.immutable_arguments = true

      MutatingRetryJob.perform_later({ original: "value" })

      assert_equal [
        { original: "value" },
        { original: "value" },
        { original: "value" }
      ], JobBuffer.values
    end

    test "mutating self.arguments still affects retries when immutable_arguments is enabled" do
      ActiveJob.immutable_arguments = true

      ArgumentsMutationRetryJob.perform_later({ foo: "bar" })

      assert_equal [
        { foo: "bar" },
        { foo: "bar", from_arguments: true }
      ], JobBuffer.values
      assert JobBuffer.values.none? { |value| value.key?(:from_perform) }
    end

    test "retries preserve nested arguments and keyword arguments when immutable_arguments is enabled" do
      ActiveJob.immutable_arguments = true
      data = ActiveSupport::HashWithIndifferentAccess.new(list: [1, 2], name: +"bob", nested: { count: 0 })

      NestedMutationRetryJob.perform_later(data, options: { mode: "original" })

      expected = [
        ActiveSupport::HashWithIndifferentAccess.new(list: [1, 2], name: "bob", nested: { count: 0 }),
        { mode: "original" },
        ActiveSupport::HashWithIndifferentAccess
      ]
      assert_equal [expected, expected], JobBuffer.values
    end
  end

  test "keyword arguments are passed to perform when immutable_arguments is enabled" do
    ActiveJob.immutable_arguments = true

    KwargsJob.perform_now(argument: 2)

    assert_equal "Job with argument: 2", JobBuffer.last_value
  end

  test "Global ID arguments are passed to perform as-is when immutable_arguments is enabled" do
    ActiveJob.immutable_arguments = true
    person = Person.new(5)

    GlobalIDIdentityJob.perform_now(person)

    assert_same person, JobBuffer.last_value
  end
end
