require "linkmap_ios/version"
require "filesize"
require "json"

module LinkmapIos
  Library = Struct.new(:name, :size, :objects)

  class LinkmapParser
    attr_reader :id_map
    attr_reader :library_map

    def initialize(file_path)
      @file_path = file_path
      @id_map = {}
      @library_map = {}
    end

    def hash
      # Cache
      return @result_hash if @result_hash

      parse

      total_size = @library_map.values.map(&:size).inject(:+)
      detail = @library_map.values.map { |lib| {:library => lib.name, :size => lib.size, :dead_size => lib.dead_size, :objects => lib.objects.map { |o| @id_map[o][:object] }}}
      total_dead_size = @library_map.values.map(&:dead_size).inject(:+)

      # puts total_size
      # puts detail

      @result_hash = {:total => total_size, :detail => detail, :total_dead => total_dead_size}
      @result_hash
    end

    def json
      JSON.pretty_generate(hash)
    end

    def report
      result = hash

      report = "# Total size\n"
      report << "#{Filesize.from(result[:total].to_s + 'B').pretty}\n"
      report << "# Dead Size\n"
      report << "#{Filesize.from(result[:total_dead].to_s + 'B').pretty}\n"
      report << "\n# Library detail\n"
      result[:detail].sort_by { |h| h[:size] }.reverse.each do |lib|
        report << "#{lib[:library]}   #{Filesize.from(lib[:size].to_s + 'B').pretty}\n"
      end
      report << "\n# Object detail\n"
      @id_map.each_value do |id_info|
        report << "#{id_info[:object]}   #{Filesize.from(id_info[:size].to_s + 'B').pretty}\n"
      end

      report
    end

    private

    def parse
      File.foreach(@file_path).with_index do |line, line_num|
        begin
          # Deal with string like 
          unless line.valid_encoding?
            line = line.encode("UTF-16", :invalid => :replace, :replace => "?").encode('UTF-8')
            # puts "#{line_num}: #{line}"
          end

          if line.start_with? "#"
            if line.start_with? "# Object files:"
              @subparser = :parse_object_files
            elsif line.start_with? "# Sections:"
              @subparser = :parse_sections
            elsif line.start_with? "# Symbols:"
              @subparser = :parse_symbols
            elsif line.start_with? '# Dead Stripped Symbols:'
              @subparser = :parse_dead
            end
          else
            send(@subparser, line)
          end
        rescue => e
          puts "Exception on Link map file line #{line_num}. Content is"
          puts line
          raise e
        end
      end

      # puts @id_map
      # puts @library_map
    end

    def parse_object_files(text)
      if text =~ /\[(.*)\].*\/(.*)\((.*)\)/
        # Sample:
        # [  6] SomePath/Release-iphoneos/ReactiveCocoa/libReactiveCocoa.a(MKAnnotationView+RACSignalSupport.o)
        # So $1 is id. $2 is library
        id = $1.to_i
        @id_map[id] = {:library => $2, :object => $3}

        library = (@library_map[$2] or Library.new($2, 0, [], 0))
        library.objects << id
        @library_map[$2] = library
      elsif text =~ /\[(.*)\].*\/(.*)/
        # Sample:
        # System
        # [100] /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS9.3.sdk/System/Library/Frameworks//UIKit.framework/UIKit.tbd
        # Main
        # [  3] /SomePath/Release-iphoneos/CrashDemo.build/Objects-normal/arm64/AppDelegate.o
        # Dynamic Framework
        # [9742] /SomePath/Pods/AFNetworking/Classes/AFNetworking.framework/AFNetworking
        id = $1.to_i
        if text.include?('.framework') and not $2.include?('.')
          lib = $2
        else
          lib = $2.end_with?('.tbd') ? 'System' : 'Main'
        end
        @id_map[id] = {:library => lib, :object => $2}

        library = (@library_map[lib] or Library.new(lib, 0, [], 0))
        library.objects << id
        @library_map[lib] = library
      end
    end

    def parse_sections(text)
      # Do nothing
    end

    def parse_symbols(text)
      # Sample
      # 0x1000055C8	0x0000003C	[  4] -[FirstViewController viewWillAppear:]
      if text =~ /^0x.+?\s+0x(.+?)\s+\[(.+?)\]/
        id_info = @id_map[$2.to_i]
        if id_info
          id_info[:size] = (id_info[:size] or 0) + $1.to_i(16)
          @library_map[id_info[:library]].size += $1.to_i(16)
        end
      end
    end

    def parse_dead(text)
      # <<dead>>  0x00000008  [  3] literal string: v16@0:8
      if text =~ /^<<dead>>\s+0x(.+?)\s+\[(.+?)\]\w*/
        id_info = @id_map[$2.to_i]
        if id_info
          id_info[:dead_size] = (id_info[:dead_size] or 0) + $1.to_i(16)
          @library_map[id_info[:library]].dead_size += $1.to_i(16)
        end
      end
    end

  end
end
