require 'spec_helper'

describe Bosh::Director::NatsRpc do
  let(:nats) { instance_double(NATS::IO::Client) }
  let(:nats_url) { 'fake-nats-url' }
  let(:nats_server_ca_path) { '/path/to/happiness.pem' }
  let(:nats_client_private_key_path) { '/path/to/success.pem' }
  let(:nats_client_certificate_path) { '/path/to/enlightenment.pem' }
  let(:max_reconnect_attempts) { 4 }
  let(:reconnect_time_wait) { 2 }
  let(:nats_options) do
    {
      uris: Array.new(max_reconnect_attempts, nats_url),
      max_reconnect_attempts: max_reconnect_attempts,
      reconnect_time_wait: reconnect_time_wait,
      reconnect: true,
      ssl: true,
      tls: {
        private_key_file: nats_client_private_key_path,
        cert_chain_file: nats_client_certificate_path,
        verify_peer: true,
        ca_file: nats_server_ca_path,
      },
    }
  end
  let(:some_logger) { instance_double(Logger) }
  let(:options) do
    {}
  end

  subject(:nats_rpc) do
    Bosh::Director::NatsRpc.new(nats_url, nats_server_ca_path, nats_client_private_key_path, nats_client_certificate_path)
  end

  before do
    allow(Bosh::Director::NatsClient).to receive(:options).and_return(nats_options)
    allow(nats).to receive(:connected?).and_return(false, true)
    allow(nats).to receive(:connect)
    allow(nats).to receive(:on_error)
    allow(NATS::IO::Client).to receive(:new).and_return(nats)
    allow(Bosh::Director::Config).to receive(:logger).and_return(some_logger)
    allow(some_logger).to receive(:debug)
    allow(Bosh::Director::Config).to receive(:process_uuid).and_return(123)
  end

  describe '#nats' do
    context 'when an error occurs while connecting' do
      before do
        allow(nats).to receive(:connect).with(nats_options).and_raise('a NATS error has occurred')
        allow(nats).to receive(:connected?).and_return(false)
        allow(nats).to receive(:on_error)
      end

      it 'throws the error' do
        expect do
          nats_rpc.nats
        end.to raise_error('An error has occurred while connecting to NATS: a NATS error has occurred')
      end
    end

    context 'When NATS on_error handler is invoked' do
      let(:nats_url) { 'nats://nats:some_nats_password@127.0.0.1:4222' }

      before do
        allow(nats).to receive(:connect).with(nats_options).and_return(nats)
        allow(nats).to receive(:on_error)
          .and_yield('Some error for nats://nats:some_nats_password@127.0.0.1:4222. '\
                     'Another error for nats://nats:some_nats_password@127.0.0.1:4222.')
      end

      it 'does NOT log the NATS password' do
        nats_rpc.nats
        expect(some_logger).to receive(:error)
          .with('NATS client error: Some error for nats://nats:*******@127.0.0.1:4222. '\
                'Another error for nats://nats:*******@127.0.0.1:4222.')
      end
    end
  end

  describe 'send_request' do
    before do
      allow(nats_rpc).to receive(:generate_request_id).and_return('req1')
    end

    it 'should publish a message to the client' do
      expect(nats).to receive(:subscribe).with('director.123.>')
      expect(nats).to receive(:publish) do |subject, message|
        expect(subject).to eql('test_client')
        payload = JSON.parse(message)
        expect(payload).to eql(
          'method' => 'a',
          'arguments' => [5],
          'reply_to' => 'director.123.client_id_567.req1',
        )
      end

      request_id = nats_rpc.send_request('test_client', 'client_id_567', { 'method' => 'a', 'arguments' => [5] }, options)
      expect(request_id).to eql('req1')
    end

    it 'should execute the callback when the message is received' do
      subscribe_callback = nil
      expect(nats).to receive(:subscribe).with('director.123.>') do |&block|
        subscribe_callback = block
      end
      expect(nats).to receive(:publish) do
        subscribe_callback.call('', nil, 'director.123.client_id_567.req1')
      end

      callback_called = false
      nats_rpc.send_request('test_client', 'client_id_567', { 'method' => 'a', 'arguments' => [5] }, options) do
        callback_called = true
      end
      expect(callback_called).to be(true)
    end

    it 'should execute the callback once even when two messages were received' do
      subscribe_callback = nil
      expect(some_logger).to_not receive(:warn)
      expect(nats).to receive(:subscribe).with('director.123.>') do |&block|
        subscribe_callback = block
      end
      expect(nats).to receive(:publish) do
        subscribe_callback.call('', nil, 'director.123.client_id_567.req1')
        subscribe_callback.call('', nil, 'director.123.client_id_567.req1')
      end

      called_times = 0
      nats_rpc.send_request('test_client', 'client_id_567', { 'method' => 'a', 'arguments' => [5] }, options) do
        called_times += 1
      end
      expect(called_times).to eql(1)
    end

    context 'logging' do
      let(:arguments) do
        [{
          'blob_id' => '1234-5678',
          'checksum' => 'QWERTY',
          'payload' => 'ASDFGH',
        }]
      end

      it 'logs redacted payload and checksum message in the debug logs for upload_blob call' do
        expect(some_logger).to receive(:debug).with('SENT: test_upload_blob {"method":"upload_blob","arguments":[{"blob_id":"1234-5678","checksum":"<redacted>","payload":"<redacted>"}],"reply_to":"director.123.client_id_567.req1"}')
        expect(nats).to receive(:subscribe).with('director.123.>')
        expect(nats).to receive(:publish) do |subject, message|
          expect(subject).to eql('test_upload_blob')
          payload = JSON.parse(message)
          expect(payload).to eql(
            'method' => 'upload_blob',
            'arguments' => arguments,
            'reply_to' => 'director.123.client_id_567.req1',
          )
        end

        request_id = nats_rpc.send_request(
          'test_upload_blob',
          'client_id_567',
          { method: :upload_blob, arguments: arguments },
          options,
        )
        expect(request_id).to eql('req1')
      end

      it 'does NOT redact other messages arguments calls' do
        expect(some_logger).to receive(:debug).with('SENT: test_any_method {"method":"any_method","arguments":'\
        '[{"blob_id":"1234-5678","checksum":"QWERTY","payload":"ASDFGH"}],"reply_to":"director.123.client_id_567.req1"}')
        expect(nats).to receive(:subscribe).with('director.123.>')
        expect(nats).to receive(:publish) do |subject, message|
          expect(subject).to eql('test_any_method')
          payload = JSON.parse(message)
          expect(payload).to eql(
            'method' => 'any_method',
            'arguments' => arguments,
            'reply_to' => 'director.123.client_id_567.req1',
          )
        end

        request_id = nats_rpc.send_request(
          'test_any_method',
          'client_id_567',
          { method: :any_method, arguments: arguments },
          options,
        )
        expect(request_id).to eql('req1')
      end

      it 'if passed options with logging=false, it does not log' do
        expect(some_logger).to_not receive(:debug)

        subscribe_callback = nil
        allow(nats).to receive(:subscribe).with('director.123.>') do |&block|
          subscribe_callback = block
        end

        allow(nats).to receive(:publish) do
          subscribe_callback.call('success response', nil, 'director.123.client_id_567.req1')
        end

        nats_rpc.send_request(
          'test_upload_blob',
          'client_id_567',
          { method: :upload_blob, arguments: arguments },
          { 'logging' => false },
        )
      end
    end
  end

  describe 'cancel_request' do
    before do
      allow(nats_rpc).to receive(:generate_request_id).and_return('req1')
    end

    it 'should not fire after cancel was called' do
      subscribe_callback = nil
      expect(nats).to receive(:subscribe).with('director.123.>') do |&block|
        subscribe_callback = block
      end
      expect(nats).to receive(:publish)

      called = false
      request_id = nats_rpc.send_request('test_client', 'client_id_567', { 'method' => 'a', 'arguments' => [5] }, options) do
        called = true
      end
      expect(request_id).to eql('req1')

      nats_rpc.cancel_request('req1')
      subscribe_callback.call('', nil, 'director.123.client_id_567.req1')
      expect(called).to be(false)
    end
  end
end
