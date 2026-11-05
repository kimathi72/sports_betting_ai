# Prospective evaluation sweep.
#
#   rake predictions:sweep            # PREVIEW — reports what would be scored
#   APPLY=1 rake predictions:sweep    # writes the evaluation records
#
# Deliberately NOT wired to a scheduler. Enabling it on a timer is a policy
# decision (what cadence, who sees the report), not a technical one, and this
# project has already documented why background jobs are started deliberately
# rather than by accident (handout §8.6).
namespace :predictions do
  desc "Score issued predictions whose match has finished (preview unless APPLY=1)"
  task sweep: :environment do
    apply = ENV["APPLY"].to_s.match?(/\A(1|true|yes)\z/i)

    report = Predictions::ProspectiveSweep.new.call(apply: apply)

    mode = apply ? "APPLY" : "PREVIEW (nothing written; set APPLY=1 to write)"
    puts "predictions:sweep — #{mode}"
    puts "  eligible/evaluated : #{report.evaluated.size}"
    puts "  pending (unfinished): #{report.pending}"
    puts "  refused            : #{report.refused.size}"

    report.refused_reasons.each { |reason, count| puts "    #{reason}: #{count}" }
    report.evaluated.first(20).each do |row|
      puts "    prediction #{row[:prediction_id]} market=#{row[:market]} " \
           "actual=#{row[:actual] || '-'} correct=#{row.key?(:correct) ? row[:correct] : '-'}"
    end

    if report.evaluated.empty? && report.pending.zero?
      puts "\nNo prospective evidence yet. A prediction counts only when it was issued"
      puts "before kickoff, carries a verified model freeze digest, and its match has"
      puts "completed since."
    end
  end
end
