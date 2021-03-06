require 'webhdfs'
require 'dumbo/time_ext'

module Dumbo
  class Firehose
    class HDFS
      def initialize(namenodes, sources)
        [namenodes].flatten.each do |host|
          begin
            $log.info("connecting to", namenode: host)
            @hdfs = WebHDFS::Client.new(host, 50070)
            @hdfs.list('/')
            break
          rescue
            $log.info("failed to use", namenode: host)
            @hdfs = nil
          end
        end
        raise "no namenode is up and running" unless @hdfs
        @hdfs_cache = {}
        @sources = sources
      end

      def slots(topic, interval)
        slots!(topic, interval, @hdfs_cache)
      end

      def slots!(topic, interval, cache = {})
        interval = interval.map { |t| t.floor(1.hour).utc }
        $log.info("scanning HDFS for", interval: interval)
        interval = (interval.first.to_i..interval.last.to_i)
        interval.step(1.hour).map do |time|
          Slot.new(@sources, @hdfs, cache, topic, Time.at(time).utc)
        end.reject do |slot|
          slot.events.to_i < 1
        end
      end

      class Slot
        attr_reader :topic, :time, :paths, :events

        def initialize(sources, hdfs, hdfs_cache, topic, time)
          @sources = sources
          @hdfs = hdfs
          @hdfs_cache = hdfs_cache
          @topic = topic
          @time = time
          @paths = paths!
          @events = @paths.map do |path|
            File.basename(path).split('.')[3].to_i
          end.reduce(:+)
        end

        def patterns
          @paths.map do |path|
            tokens = path.split('/')
            suffix = tokens[-1].split('.')
            tokens[-1] = "*.#{suffix[-1]}"
            tokens.join('/')
          end.compact.uniq.sort
        end

        def paths!
          begin
            [@sources[@topic]['input']['gobblin'], @sources[@topic]['input']['gobblinStale']].flatten.compact.uniq.map do |hdfs_root|
              hdfs_root = hdfs_root.match(/^(hdfs\:\/\/.*?)?(\/.*$)/)[2]
              path = "#{hdfs_root}/#{@time.strftime("%Y/%m/%d/%H")}"
              begin
                @hdfs_cache[path] ||= @hdfs.list(path).map do |entry|
                  File.join(path, entry['pathSuffix']) if entry['pathSuffix'] =~ /\.gz$/
                end
              rescue => e
                []
              end
            end.flatten.compact
          rescue
            $log.error("#{@topic} -> input.gobblin must be an array of HDFS paths")
            exit 1
          end
        end
      end
    end
  end
end
