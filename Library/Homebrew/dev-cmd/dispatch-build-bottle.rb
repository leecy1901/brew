# typed: true
# frozen_string_literal: true

require "cli/parser"
require "utils/github"

module Homebrew
  extend T::Sig

  module_function

  sig { returns(CLI::Parser) }
  def dispatch_build_bottle_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Build bottles for these formulae with GitHub Actions.
      EOS
      flag   "--tap=",
             description: "Target tap repository (default: `homebrew/core`)."
      flag   "--timeout=",
             description: "Build timeout (in minutes, default: 60)."
      flag   "--issue=",
             description: "If specified, post a comment to this issue number if the job fails."
      comma_array "--macos=",
                  description: "Version(s) of macOS the bottle should be built for."
      flag   "--workflow=",
             description: "Dispatch specified workflow (default: `dispatch-build-bottle.yml`)."
      switch "--upload",
             description: "Upload built bottles."
      switch "--linux",
             description: "Dispatch bottle for Linux (using GitHub runners)."
      switch "--linux-self-hosted",
             description: "Dispatch bottle for Linux (using self-hosted runner)."
      switch "--linux-wheezy",
             description: "Use Debian Wheezy container for building the bottle on Linux."

      conflicts "--linux", "--linux-self-hosted"
      named_args :formula, min: 1
    end
  end

  def dispatch_build_bottle
    args = dispatch_build_bottle_args.parse

    tap = Tap.fetch(args.tap || CoreTap.instance.name)
    user, repo = tap.full_name.split("/")
    ref = "master"
    workflow = args.workflow || "dispatch-build-bottle.yml"

    runners = []

    if (macos = args.macos&.compact_blank) && macos.present?
      runners += macos.map do |element|
        # We accept runner name syntax (11-arm64) or bottle syntax (arm64_big_sur)
        os, arch = element.yield_self do |s|
          tag = Utils::Bottles::Tag.from_symbol(s.to_sym)
          [tag.to_macos_version, tag.arch]
        rescue ArgumentError, MacOSVersionError
          os, arch = s.split("-", 2)
          [MacOS::Version.new(os), arch&.to_sym]
        end

        if arch.present? && arch != :x86_64
          "#{os}-#{arch}"
        else
          os.to_s
        end
      end
    end

    if args.linux?
      runners << "ubuntu-latest"
    elsif args.linux_self_hosted?
      runners << "linux-self-hosted-1"
    end

    raise UsageError, "Must specify --macos or --linux or --linux-self-hosted option" if runners.empty?

    args.named.to_resolved_formulae.each do |formula|
      # Required inputs
      inputs = {
        runner:  runners.join(","),
        formula: formula.name,
      }

      # Optional inputs
      # These cannot be passed as nil to GitHub API
      inputs[:timeout] = args.timeout if args.timeout
      inputs[:issue] = args.issue if args.issue
      inputs[:upload] = args.upload?.to_s if args.upload?
      inputs[:wheezy] = args.linux_wheezy?.to_s if args.linux_wheezy?

      ohai "Dispatching #{tap} bottling request of formula \"#{formula.name}\" for #{runners.join(", ")}"
      GitHub.workflow_dispatch_event(user, repo, workflow, ref, inputs)
    end
  end
end
