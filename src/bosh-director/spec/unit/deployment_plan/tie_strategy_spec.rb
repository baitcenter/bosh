require 'spec_helper'

module Bosh::Director::DeploymentPlan
  module PlacementPlanner
    describe TieStrategy do
      let(:az1) { AvailabilityZone.new("1", {}) }
      let(:az2) { AvailabilityZone.new("2", {}) }
      let(:az3) { AvailabilityZone.new("3", {}) }

      describe TieStrategy::MinWins do
        subject { described_class.new(%w(3 3)) }

        it 'chooses the minimum' do
          expect(subject.call([az1, az2])).to eq(az1)
        end

        it 'prioritizes the priority' do
          expect(subject.call([az2, az3])).to eq(az3)
        end

        it 'deletes an item from priority when we match based on priority' do
          expect(subject.call([az1, az2, az3])).to eq(az3)
          expect(subject.call([az1, az2, az3])).to eq(az3)
          expect(subject.call([az1, az2, az3])).to eq(az1)
        end
      end

      describe TieStrategy::RandomWins do
        subject { described_class.new(%w(3 3), random: fake_random) }

        let(:fake_random) do
          r = Object.new
          def r.rand(n)
            1
          end
          r
        end

        it 'chooses a random az' do
          expect(subject.call([az1, az2])).to eq(az2)
        end

        it 'prioritizes the priority' do
          expect(subject.call([az1, az2, az3])).to eq(az3)
        end

        it 'deletes an item from priority when we match based on priority' do
          expect(subject.call([az1, az2, az3])).to eq(az3)
          expect(subject.call([az1, az2, az3])).to eq(az3)
          expect(subject.call([az1, az2, az3])).to eq(az2)
        end
      end
    end
  end
end
