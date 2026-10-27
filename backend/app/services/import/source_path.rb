module Import
  # Decides whether a caller-supplied path may be imported.
  #
  # Job arguments come from outside the process (a CLI, a queued message), so a
  # path is untrusted input. Without a boundary, a mistake or a typo could point
  # the importer at `/etc/passwd`, a mounted secret, or anywhere else the process
  # can read. Everything is therefore resolved to a real path and required to sit
  # inside one of a small set of approved roots.
  #
  # The roots are the repository's `data/` directory (mounted at `/data` in
  # Docker) and its fixtures, plus `IMPORT_ALLOWED_ROOTS` when an operator needs
  # to stage files elsewhere. The override is a *colon-separated list of
  # directories*, never a file, so a stray environment variable cannot widen
  # access to a single sensitive path.
  class SourcePath
    # Where imports may come from. `/data` is the Compose mount; the Rails-root
    # relative entries cover running the suite and local development.
    DEFAULT_ROOTS = [
      "/data",
      Rails.root.join("..", "data").to_s,
      Rails.root.join("data").to_s,
    ].freeze

    class NotPermitted < StandardError; end

    def self.allowed_roots
      extra = ENV.fetch("IMPORT_ALLOWED_ROOTS", "").split(File::PATH_SEPARATOR)
        .reject { |root| root.strip.empty? }
      (DEFAULT_ROOTS + extra).map { |root| realdir(root) }.compact.uniq
    end

    def self.realdir(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    def self.validate!(path)
      new(path).validate!
    end

    def initialize(path)
      @path = path.to_s
    end

    attr_reader :path

    # Returns the resolved absolute path when permitted, or raises NotPermitted
    # with an operator-readable reason. Messages never echo directory listings.
    def validate!
      raise NotPermitted, "a file path is required" if path.strip.empty?
      raise NotPermitted, "the file path must be absolute (got #{path.inspect})" unless File.absolute_path?(path)
      raise NotPermitted, "file not found: #{File.basename(path)}" unless File.file?(path)

      resolved = begin
          File.realpath(path)
        rescue SystemCallError
          raise NotPermitted, "file not found: #{File.basename(path)}"
        end

      unless permitted?(resolved)
        raise NotPermitted,
              "#{File.basename(path)} is outside the allowed import directory"
      end

      resolved
    end

    private

    # Comparison happens on real paths, so a symlink cannot smuggle a file in
    # from elsewhere. `File.fnmatch` on a trailing separator keeps `/data2` from
    # matching the `/data` root.
    def permitted?(resolved)
      self.class.allowed_roots.any? do |root|
        resolved.start_with?(root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}")
      end
    end
  end
end
