require 'spec_helper'
require 'webmock/rspec'
require 'puppet/http'

describe Puppet::HTTP::Service::FileServer do
  include PuppetSpec::Files

  let(:ssl_context) { Puppet::SSL::SSLContext.new }
  let(:client) { Puppet::HTTP::Client.new(ssl_context: ssl_context) }
  let(:subject) { client.create_session.route_to(:fileserver) }
  let(:environment) { 'testing' }
  let(:report) { Puppet::Transaction::Report.new }

  before :each do
    Puppet[:server] = 'www.example.com'
    Puppet[:masterport] = 443
  end

  context 'when making requests' do
    let(:uri) {"https://www.example.com:443/puppet/v3/file_content/:mount/:path"}

    it 'includes default HTTP headers' do
      stub_request(:get, uri).with do |request|
        expect(request.headers).to include({'X-Puppet-Version' => /./, 'User-Agent' => /./})
        expect(request.headers).to_not include('X-Puppet-Profiling')
      end

      subject.get_file_content(mount_point: ':mount', path: ':path')
    end

    it 'includes the X-Puppet-Profiling header when Puppet[:profile] is true' do
      stub_request(:get, uri).with(headers: {'X-Puppet-Version' => /./, 'User-Agent' => /./, 'X-Puppet-Profiling' => 'true'})

      Puppet[:profile] = true

      subject.get_file_content(mount_point: ':mount', path: ':path')
    end
  end

  context 'when routing to the file service' do
    it 'defaults the server and port based on settings' do
      Puppet[:server] = 'file.example.com'
      Puppet[:masterport] = 8141

      stub_request(:get, "https://file.example.com:8141/puppet/v3/file_content/mount/path")

      subject.get_file_content(mount_point: 'mount', path: 'path')
    end
  end

  context 'retriving file metadata' do
    let(:path) { tmpfile('get_file_metadata') }
    let(:url) { "https://www.example.com/puppet/v3/file_metadata/infinity/#{path}?checksum_type=md5&environment=testing&links=manage&source_permissions=ignore" }
    let(:filemetadata) { Puppet::FileServing::Metadata.new(path) }

    it 'submits a request for file metadata to the server' do
      stub_request(:get, url).with(
        headers: {'Accept'=>'application/json, application/x-msgpack, text/pson',}
      ).to_return(
        status: 200, body: filemetadata.render, headers: { 'Content-Type' => 'application/json' }
      )

      metadata = subject.get_file_metadata(mount_point: 'infinity', path: path, environment: environment)
      expect(metadata.path).to eq(path)
    end

    it 'raises a protocol error if the Content-Type header is missing from the response' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: {})

      expect {
        subject.get_file_metadata(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::ProtocolError, "No content type in http response; cannot parse")
    end

    it 'raises an error if the Content-Type is unsupported' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/yaml' })

      expect {
        subject.get_file_metadata(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::ProtocolError, "Content-Type is unsupported")
    end

    it 'raises response error if unsuccessful' do
      stub_request(:get, url).to_return(status: [400, 'Bad Request'])

      expect {
        subject.get_file_metadata(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error do |err|
        expect(err).to be_an_instance_of(Puppet::HTTP::ResponseError)
        expect(err.message).to eq('Bad Request')
        expect(err.response.code).to eq(400)
      end
    end

    it 'raises a serialization error if serialization fails' do
      stub_request(:get, url).to_return(
        status: 200, body: '', headers: { 'Content-Type' => 'application/json' }
      )

      expect {
        subject.get_file_metadata(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::SerializationError, /Failed to deserialize Puppet::FileServing::Metadata from json/)
    end
  end

  context 'retriving multiple file metadatas' do
    let(:path) { tmpfile('get_file_metadatas') }
    let(:url) { "https://www.example.com/puppet/v3/file_metadatas/infinity/#{path}?checksum_type=md5&links=manage&recurse=false&source_permissions=ignore" }
    let(:filemetadatas) { [Puppet::FileServing::Metadata.new(path)] }
    let(:formatter) { Puppet::Network::FormatHandler.format(:json) }

    it 'submits a request for file metadata to the server' do
      stub_request(:get, url).with(
        headers: {'Accept'=>'application/json, application/x-msgpack, text/pson',}
      ).to_return(
        status: 200, body: formatter.render_multiple(filemetadatas), headers: { 'Content-Type' => 'application/json' }
      )

      metadatas = subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment)
      expect(metadatas.first.path).to eq(path)
    end

    it 'automatically converts an array of parameters to the stringified query' do
      url = "https://www.example.com/puppet/v3/file_metadatas/infinity/#{path}?checksum_type=md5&ignore=CVS&ignore=.git&ignore=.hg&links=manage&recurse=false&source_permissions=ignore"
      stub_request(:get, url).with(
        headers: {'Accept'=>'application/json, application/x-msgpack, text/pson',}
      ).to_return(
        status: 200, body: formatter.render_multiple(filemetadatas), headers: { 'Content-Type' => 'application/json' }
      )

      metadatas = subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment, ignore: ['CVS', '.git', '.hg'])
      expect(metadatas.first.path).to eq(path)
    end

    it 'raises a protocol error if the Content-Type header is missing from the response' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: {})

      expect {
        subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::ProtocolError, "No content type in http response; cannot parse")
    end

    it 'raises an error if the Content-Type is unsupported' do
      stub_request(:get, url).to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/yaml' })

      expect {
        subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::ProtocolError, "Content-Type is unsupported")
    end

    it 'raises response error if unsuccessful' do
      stub_request(:get, url).to_return(status: [400, 'Bad Request'])

      expect {
        subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error do |err|
        expect(err).to be_an_instance_of(Puppet::HTTP::ResponseError)
        expect(err.message).to eq('Bad Request')
        expect(err.response.code).to eq(400)
      end
    end

    it 'raises a serialization error if serialization fails' do
      stub_request(:get, url).to_return(
        status: 200, body: '', headers: { 'Content-Type' => 'application/json' }
      )

      expect {
        subject.get_file_metadatas(mount_point: 'infinity', path: path, environment: environment)
      }.to raise_error(Puppet::HTTP::SerializationError, /Failed to deserialize multiple Puppet::FileServing::Metadata from json/)
    end
  end

  context 'getting file content' do
    let(:uri) {"https://www.example.com:443/puppet/v3/file_content/infinity/eternal"}

    it 'submits a request for the file content' do
      stub_request(:get, uri).with do |request|
        expect(request.headers).to include({'Accept' => 'application/octet-stream'})
      end.to_return(status: 200, body: '')

      subject.get_file_content(mount_point: 'infinity', path: 'eternal')
    end

    it 'raises response error if unsuccessful' do
      stub_request(:get, uri).to_return(status: [400, 'Bad Request'])

      expect {
        subject.get_file_content(mount_point: 'infinity', path: 'eternal')
      }.to raise_error do |err|
        expect(err).to be_an_instance_of(Puppet::HTTP::ResponseError)
        expect(err.message).to eq('Bad Request')
        expect(err.response.code).to eq(400)
      end
    end
  end
end
