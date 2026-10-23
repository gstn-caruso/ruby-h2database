# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'stringio'
require 'digest'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2/mvstore'
m = H2::MVStore
jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
command = [java,'-cp',jar,File.join(__dir__,'StreamStoreOracle.java')]
run = lambda do |*arguments, input: ''|
  output,error,status = Open3.capture3(*command,*arguments,stdin_data: input)
  abort "#{error}\n#{output}" unless status.success?
  output
end
data = ->(length,seed) { Array.new(length) { (it * 31 + seed * 17 + (it >> 8)) & 255 }.pack('C*') }
encoded = lambda do |codec,value|
  buffer = m::Buffer.new
  codec.write(buffer,value)
  buffer.data.unpack1('H*')
end
snapshot = ->(map) { map.sort_by(&:first).map { |key,bytes| "#{key}:#{bytes.bytesize}:#{Digest::SHA256.hexdigest(bytes)};" }.join }
cases = []
[[0,128],[1,8],[4,16],[10,20],[10,100],[64,128],[256,1024],[256,262144]].each do |minimum,maximum|
  sizes = [0,1,2,3,minimum - 1,minimum,minimum + 1,maximum - 1,maximum,maximum + 1,maximum * 2,maximum * 3 + 7].select { it >= 0 }.uniq
  sizes.product([0,123],[0,3]).each do |length,key,short|
    cases << ['S',minimum,maximum,key,length,length % 19,short,key.zero? ? 5 : 0].join("\t")
  end
end
cases << "S\t4\t16\t-5\t8\t1\t0\t0"
['','80ff','010200',data.call(300,7).unpack1('H*')].product([-3,0,2_147_483_647,-2_147_483_648],[0,127,128,(1 << 63) - 1,-(1 << 63)],[0,-1,(1 << 63) - 1,-(1 << 63)]).each do |id,table,length,hash|
  cases << ['M',id,table,length,hash].join("\t")
end
references = [nil] + ['', '00','7f','80','ff','0000','80ff','ff00'].product([-1,0,(1 << 63) - 1])
references.product(references).each do |left,right|
  cases << ['C',left&.first || '-',left&.last || 0,right&.first || '-',right&.last || 0].join("\t")
end
expected = run.call(input: cases.join("\n") + "\n").split("END\n")
abort 'Stream reference result count differs' unless expected.length == cases.length
cases.zip(expected).each_with_index do |(line,wanted),index|
  fields = line.split("\t",-1)
  lines = []
  case fields.first
  when 'S'
    _,minimum,maximum,key,length,seed,short,existing = fields.map.with_index { |value,i| i.zero? ? value : value.to_i }
    map = existing.times.to_h { [it,[it].pack('C')] }
    writes = []
    store = m::StreamStore.new(map,min_block_size: minimum,max_block_size: maximum,on_store: ->(bytes) { writes << bytes })
    store.next_key = key
    input = Class.new(StringIO) do
      attr_accessor :short
      def read(length) = super(short.zero? ? length : [length,short].min)
    end.new(data.call(length,seed))
    input.short = short
    id = store.put(input)
    lines << ['S',id.unpack1('H*'),store.next_key,store.length(id),store.in_place?(id),store.max_block_key(id),Digest::SHA256.hexdigest(store.get(id).read),writes.map { "#{it}," }.join,snapshot.call(map)].join("\t")
    [0,1,maximum + 3,length + 3].each do |skip|
      reader = store.get(id)
      moved = reader.skip(skip)
      first = begin reader.readpartial(3); rescue EOFError; nil; end
      rest = reader.read
      reader.close
      lines << ['R',moved,first&.bytesize || -1,first&.unpack1('H*') || '',Digest::SHA256.hexdigest(rest),reader.getbyte || -1].join("\t")
    end
    store.remove(id)
    lines << "D\t#{snapshot.call(map)}"
  when 'M'
    _,id,table,length,hash = fields
    value = m::BlobMetadata.new([id].pack('H*'),table.to_i,length.to_i,hash.to_i)
    reference = m::BlobReference.new([id].pack('H*'),length.to_i)
    meta = encoded.call(m::Codecs::BLOB_META,value)
    ref = encoded.call(m::Codecs::BLOB_REFERENCE,reference)
    lines << ['M',meta,ref,encoded.call(m::Codecs::BLOB_META,m::Codecs::BLOB_META.read(m::Buffer.new([meta].pack('H*')))),encoded.call(m::Codecs::BLOB_REFERENCE,m::Codecs::BLOB_REFERENCE.read(m::Buffer.new([ref].pack('H*'))))].join("\t")
  when 'C'
    left = fields[1] == '-' ? nil : m::BlobReference.new([fields[1]].pack('H*'),fields[2].to_i)
    right = fields[3] == '-' ? nil : m::BlobReference.new([fields[3]].pack('H*'),fields[4].to_i)
    lines << "C\t#{m::Codecs::BLOB_REFERENCE.compare(left,right) <=> 0}"
  end
  actual = lines.join("\n") + "\n"
  abort "Stream vector #{index} differs: #{line}\nJava: #{wanted}\nRuby: #{actual}" unless actual == wanted
end
puts "Stream storage: #{cases.length} Java comparisons passed (canonical ids, block keys/bytes, callbacks, short reads, lazy skips, partial reads/EOF, deletion, signed LOB codecs and reference ordering)"

bugs = run.call('bugs')
abort "Java StreamStore limitations changed: #{bugs}" unless bugs == "describe\tBufferUnderflowException\ninline\t204\t238\nmaximum\t1\ncleanup\t3\noverwrite\t2\n"
store = m::StreamStore.new({},min_block_size: 10,max_block_size: 20)
store.next_key = 123
id = store.put(StringIO.new(data.call(200,0)))
raise 'Native indirect description mismatch' unless m::StreamStore.describe(id) == 'indirect block 136 len=200, length=200'
reader = store.get(['0001aa0002bbcc0002ddee'].pack('H*'))
reader.skip(2)
raise 'Native inline skip mismatch' unless reader.read.unpack1('H*') == 'ccddee'
map = {100 => "\x01".b,1 => "\x00\x01\x02".b}
raise 'Native maximum block key mismatch' unless m::StreamStore.new(map).max_block_key("\x01\x01\x64\x02\x01\x01".b) == 100
map = {}
store = m::StreamStore.new(map,min_block_size: 10,max_block_size: 20)
input = Class.new do
  def initialize = @calls = 0
  def read(length)
    @calls += 1
    raise IOError, 'broken' if @calls == 8
    "\x01".b * length
  end
end.new
begin
  store.put(input)
  abort 'Native stream input did not fail'
rescue IOError
  raise 'Native stream failure leaked blocks' unless map.empty?
end
key = (1 << 63) - 1
map = {key => "\x01".b}
store = m::StreamStore.new(map,min_block_size: 1,max_block_size: 8)
store.next_key = key
begin
  store.put(StringIO.new("\x02".b))
  abort 'Native stream key exhaustion overwrote a block'
rescue RangeError
  raise 'Native stream key exhaustion changed existing data' unless map[key] == "\x01".b
end
puts 'Five Java StreamStore limitations reproduced separately: indirect diagnostics, inline skip carry, maximum key after concatenation, orphaned nested blocks after input failure and key-range overwrite; native invariants pass independently (not counted as Java matches)'

file_native = lambda do |action,path,compression|
  m::Store.open(path,compression: compression,keys_per_page: 8) do |raw|
    blocks = raw.has_map?('lobData') ? raw.open_map('lobData') : raw.open_registered_map('lobData',key_type: :long,value_type: :bytes)
    metadata = raw.has_map?('lobMap') ? raw.open_map('lobMap') : raw.open_registered_map('lobMap',key_type: :long,value_type: :blob_meta)
    refs = raw.has_map?('lobRef') ? raw.open_map('lobRef') : raw.open_registered_map('lobRef',key_type: :blob_reference,value_type: :null)
    streams = m::StreamStore.new(blocks,min_block_size: 64,max_block_size: 1024)
    streams.next_key = (blocks.map(&:first).max || -1) + 1
    if action == 'create'
      [0,1,63,64,1024,10000,300000].each_with_index do |length,index|
        lob = index + 1
        id = streams.put(StringIO.new(data.call(length,lob)))
        metadata[lob] = m::BlobMetadata.new(id,lob.even? ? -3 : 7,length,-lob)
        refs[m::BlobReference.new(id,lob)] = m::Value.new(:null,nil)
      end
    elsif action == 'append'
      [2,5].each do |lob|
        meta = metadata.delete(lob)
        refs.delete(m::BlobReference.new(meta.stream_id,lob))
        streams.remove(meta.stream_id)
      end
      id = streams.put(StringIO.new(data.call(12345,8)))
      metadata[8] = m::BlobMetadata.new(id,9,12345,-(1 << 63))
      refs[m::BlobReference.new(id,8)] = m::Value.new(:null,nil)
    else
      lines = metadata.map { |key,value| ['M',key,encoded.call(m::Codecs::BLOB_META,value),streams.length(value.stream_id),Digest::SHA256.hexdigest(streams.get(value.stream_id).read)].join("\t") }
      lines.concat(refs.map { |key,_value| "F\t#{encoded.call(m::Codecs::BLOB_REFERENCE,key)}" })
      lines << "B\t#{snapshot.call(blocks)}"
      next lines.join("\n") + "\n"
    end
    ''
  end
end
file_checks = 0
Dir.mktmpdir('h2-stream-reference') do |directory|
  [:none,:fast,:high].each_with_index do |compression,level|
    java_path = File.join(directory,"java-#{level}.mv")
    ruby_path = File.join(directory,"ruby-#{level}.mv")
    run.call('create',java_path,level.to_s)
    file_native.call('create',ruby_path,compression)
    expected = run.call('dump',java_path)
    [file_native.call('dump',java_path,compression),file_native.call('dump',ruby_path,compression),run.call('dump',ruby_path)].each do |actual|
      abort "Initial stream files differ (#{compression})" unless actual == expected
      file_checks += 1
    end
    file_native.call('append',java_path,compression)
    run.call('append',ruby_path,level.to_s)
    expected = run.call('dump',java_path)
    [file_native.call('dump',java_path,compression),file_native.call('dump',ruby_path,compression),run.call('dump',ruby_path)].each do |actual|
      abort "Cross-written stream files differ (#{compression})" unless actual == expected
      file_checks += 1
    end
  end
  sql_path = File.join(directory,'sql-lobs')
  wanted = run.call('sql',sql_path).lines.map { it.chomp.split("\t").last }.sort
  m::Store.open("#{sql_path}.mv.db",read_only: true) do |raw|
    streams = m::StreamStore.new(raw.open_map('lobData'))
    actual = raw.open_map('lobMap').map { |_key,value| Digest::SHA256.hexdigest(streams.get(value.stream_id).read) }.sort
    abort 'Native external JDBC BLOB/CLOB payloads differ' unless actual == wanted
    file_checks += 2
  end
end
puts "Stream storage: #{file_checks} file checks passed (registered LOB metadata/references, native/Java cross-writes, all compression modes and external payloads from JDBC BLOB/CLOB columns)"
