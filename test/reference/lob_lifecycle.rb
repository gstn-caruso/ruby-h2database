# frozen_string_literal: true

require 'open3'
require 'stringio'
require 'tmpdir'
require 'digest'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2/mvstore'
m = H2::MVStore
jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
cases = []
[0,1,255,256,257,1024,262145].product([-1,0,1,255,256,257,1024]).each { |length,max| cases << "B\t#{length}\t#{max}" }
texts = ['', 'abc','café','😀x','a' * 257,'😀café' * 200,'漢😀' * 3000].map { it.encode(Encoding::UTF_16BE).unpack1('H*') }
texts.concat(%w[d800 dc00 d8000061dc00 d800d800dc00 0061d800])
texts.product([-1,0,1,2,3,63,85,86,255,256,257,4096]).each { |text,max| cases << "C\t#{text}\t#{max}" }
input = cases.join("\n") + "\n"
output,error,status = Open3.capture3(java,'-cp',jar,File.join(__dir__,'LobLifecycleOracle.java'),stdin_data: input)
abort "#{error}\n#{output}" unless status.success?
expected = output.split("END\n")
abort 'LOB lifecycle case count differs' unless expected.length == cases.length
encode = lambda do |codec,value|
  buffer = m::Buffer.new
  codec.write(buffer,value)
  buffer.data.unpack1('H*')
end
Dir.mktmpdir('h2-lob-lifecycle-reference') do |directory|
  variants = [[:be,nil],[:le,nil],[:be,1],[:be,3],[:le,1],[:utf8,nil]]
  input_checks = 0
  variants.each_with_index do |(encoding,chunk_size),variant|
    m::Store.open(File.join(directory,"data-#{variant}.mv")) do |raw|
      storage = m::LobStorage.new(raw)
      cases.zip(expected).each_with_index do |(line,wanted),index|
        family,source,max = line.split("\t",-1)
        if family == 'C' && encoding == :utf8
          break unless [source].pack('H*').force_encoding(Encoding::UTF_16BE).valid_encoding?
        end
        reader_class = Class.new(StringIO) do
          attr_accessor :chunk_size
          def read(length) = super(chunk_size ? [length,chunk_size].min : length)
        end
        value = if family == 'B'
          bytes = Array.new(source.to_i) { (it * 31 + 7) & 255 }.pack('C*')
          input = reader_class.new(bytes)
          input.chunk_size = chunk_size
          storage.create_blob(input,max_length: max.to_i)
        else
          text = [source].pack('H*').force_encoding(Encoding::UTF_16BE)
          text = text.unpack('n*').pack('v*').force_encoding(Encoding::UTF_16LE) if encoding == :le
          text = text.encode(Encoding::UTF_8) if encoding == :utf8
          input = reader_class.new(text)
          input.chunk_size = chunk_size
          storage.create_clob(input,max_length: max.to_i)
        end
        lines = []
        dump = lambda do |label,lob|
          storage.open(lob) { |reader| lines << "#{label}\t#{encode.call(m::Codecs::VALUE,lob)}\t#{Digest::SHA256.hexdigest(reader.read)}" }
        end
        snapshot = lambda do
          raw.open_map('lobMap').each { |id,meta| lines << "M\t#{id}\t#{encode.call(m::Codecs::BLOB_META,meta)}" }
          raw.open_map('tempLobMap').each { |id,stream| lines << "T\t#{id}\t#{stream.unpack1('H*')}" }
          raw.open_map('lobRef').each { |ref,_value| lines << "R\t#{encode.call(m::Codecs::BLOB_REFERENCE,ref)}" }
          lines << "N\t#{storage.next_lob_id}\t#{storage.pending_count}"
        end
        dump.call('V',value)
        if value.data.is_a?(m::LobReference)
          permanent = storage.copy_lob(value,table_id: 7)
          result = storage.copy_lob(permanent,table_id: -3)
          dump.call('P',permanent)
          dump.call('Q',result)
          snapshot.call
          storage.remove_lob(value)
          storage.remove_lob(permanent)
          storage.cleanup(oldest_version: raw.version + 1)
          dump.call('S',result)
          snapshot.call
          storage.remove_all_for_table(-3)
        end
        snapshot.call
        actual = lines.join("\n") + "\n"
        abort "LOB lifecycle #{index} differs: #{line[0,120]}\nJava: #{wanted}\nRuby: #{actual}" unless actual == wanted
        input_checks += 1
      end
      storage.close
    end
  end
  puts "LOB lifecycle: #{input_checks} native input variants match Java (UTF-8, UTF-16BE/LE and short byte reads)"
end
puts "LOB lifecycle: #{cases.length} Java scenarios passed (inline/temporary storage, UTF-16 limits, surrogate replacement, shared copies, permanent/result references, encoded maps and final-reference reclamation)"

run_java = lambda do |action,path,level = 0|
  output,error,status = Open3.capture3(java,'-cp',jar,File.join(__dir__,'LobLifecycleOracle.java'),action,path,level.to_s)
  abort "#{error}\n#{output}" unless status.success?
  output
end
native_file = lambda do |action,path,compression|
  m::Store.open("#{path}.mv.db",compression: compression) do |raw|
    storage = m::LobStorage.new(raw)
    values = raw.has_map?('lobValues') ? raw.open_map('lobValues') : raw.open_registered_map('lobValues',key_type: :long,value_type: :bytes)
    decode = ->(bytes) { m::Codecs::VALUE.read(m::Buffer.new(bytes)) }
    save = ->(id,value) { values[id] = [encode.call(m::Codecs::VALUE,value)].pack('H*') }
    if action == 'create'
      source = storage.create_blob(StringIO.new(Array.new(32768) { (it * 31 + 7) & 255 }.pack('C*')))
      first = storage.copy_lob(source,table_id: 7)
      save.call(1,first)
      save.call(2,storage.copy_lob(first,table_id: 8))
      save.call(3,storage.copy_lob(storage.create_clob(StringIO.new('😀café' * 2000)),table_id: 7))
      save.call(4,storage.create_blob(StringIO.new("\x01\x02\x03".b),max_length: 3))
      save.call(5,storage.create_clob(StringIO.new('abc'),max_length: 3))
    elsif action == 'append'
      storage.remove_lob(decode.call(values.delete(1)))
      storage.cleanup(oldest_version: raw.version + 1)
      save.call(6,storage.copy_lob(decode.call(values[3]),table_id: 8))
      storage.remove_all_for_table(7)
      values.delete(3)
      source = storage.create_blob(StringIO.new(Array.new(400000) { (it * 31 + 9) & 255 }.pack('C*')))
      save.call(7,storage.copy_lob(source,table_id: 9))
    else
      lines = values.map do |id,bytes|
        value = decode.call(bytes)
        storage.open(value) { |reader| "V#{id}\t#{bytes.unpack1('H*')}\t#{Digest::SHA256.hexdigest(reader.read)}" }
      end
      raw.open_map('lobMap').each { |id,meta| lines << "M\t#{id}\t#{encode.call(m::Codecs::BLOB_META,meta)}" }
      raw.open_map('tempLobMap').each { |id,stream| lines << "T\t#{id}\t#{stream.unpack1('H*')}" }
      raw.open_map('lobRef').each { |ref,_value| lines << "R\t#{encode.call(m::Codecs::BLOB_REFERENCE,ref)}" }
      lines << "N\t#{storage.next_lob_id}\t#{storage.pending_count}"
      storage.close
      next lines.join("\n") + "\n"
    end
    storage.close
    ''
  end
end
file_checks = 0
Dir.mktmpdir('h2-lob-files') do |directory|
  [:none,:fast,:high].each_with_index do |compression,level|
    java_path = File.join(directory,"java-#{level}")
    ruby_path = File.join(directory,"ruby-#{level}")
    run_java.call('create',java_path,level)
    native_file.call('create',ruby_path,compression)
    expected = run_java.call('dump',java_path)
    [native_file.call('dump',java_path,compression),native_file.call('dump',ruby_path,compression),run_java.call('dump',ruby_path)].each do |actual|
      abort "Initial LOB lifecycle files differ: #{compression}\n#{expected}\n#{actual}" unless actual == expected
      file_checks += 1
    end
    native_file.call('append',java_path,compression)
    run_java.call('append',ruby_path,level)
    expected = run_java.call('dump',java_path)
    [native_file.call('dump',java_path,compression),native_file.call('dump',ruby_path,compression),run_java.call('dump',ruby_path)].each do |actual|
      abort "Cross-written LOB lifecycle files differ: #{compression}\n#{expected}\n#{actual}" unless actual == expected
      file_checks += 1
    end
  end
end
puts "LOB lifecycle: #{file_checks} cross-engine file comparisons passed (shared permanent data, temp/result cleanup, CLOB counts, inline values, reopened ids, deletions/copies and all compression modes)"

observed = run_java.call('probes','')
wanted = "overflow\t0\nmissing\tNullPointerException\nreader\tIOException\nqueue\t2\n"
abort "Java LOB defect observations changed: #{observed}" unless observed == wanted
Dir.mktmpdir('h2-lob-defects') do |directory|
  m::Store.open(File.join(directory,'data.mv')) do |raw|
    m::LobStorage.open(raw) do |storage|
      value = storage.create_clob(StringIO.new('abc'),max_length: 1 << 62)
      storage.open(value) { |reader| abort 'Native CLOB length overflow' unless value.data.characters == 3 && reader.read == 'abc' }
      storage.remove_all_for_table(-2)
      begin
        storage.get_input_stream(999,table_id: 7)
        abort 'Native missing LOB was accepted'
      rescue m::Error => error
        abort 'Native missing LOB code differs' unless error.code == 50
      end
      value = storage.create_blob(StringIO.new('x' * 600000))
      storage.open(value) do |reader|
        abort 'Native LOB prefix differs' unless reader.read(1) == 'x'
        storage.remove_lob(value)
        storage.cleanup(oldest_version: raw.version + 1)
        abort 'Native reader lost later blocks' unless reader.read == 'x' * 599999
      end
      storage.cleanup(oldest_version: raw.version + 1)
      first = storage.create_blob(StringIO.new('a'))
      second = storage.create_blob(StringIO.new('b'))
      storage.remove_lob(first)
      version = raw.version
      raw.commit
      storage.remove_lob(second)
      storage.cleanup(oldest_version: version)
      storage.cleanup(oldest_version: version + 1)
      abort 'Native cleanup skipped an eligible reference' unless raw.open_map('tempLobMap').size == 1 && storage.pending_count == 1
      storage.open(second) { |reader| abort 'Native future reference was removed' unless reader.read == 'b' }
    end
  end
end
puts 'LOB lifecycle: four Java defects observed separately; native checks preserve large CLOB lengths, report missing ids, pin reader blocks and clean eligible queued references'
