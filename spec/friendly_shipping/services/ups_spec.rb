# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FriendlyShipping::Services::Ups do
  subject(:service) { described_class.new(key: ENV['UPS_KEY'], login: ENV['UPS_LOGIN'], password: ENV['UPS_PASSWORD']) }

  describe 'carriers' do
    subject { service.carriers }
    let(:ups) { FriendlyShipping::Carrier.new(code: 'ups', id: 'ups', name: 'United Parcel Service') }

    it { is_expected.to be_success }

    it 'contains UPS only' do
      expect(subject.value!).to eq([ups])
    end
  end

  describe 'SHIPPING_METHODS' do
    it 'contains all valid shipping methods' do
      described_class::SHIPPING_METHODS.each do |shipping_method|
        expect(shipping_method.name).to be_present
        expect(shipping_method.service_code).to be_present
        expect(shipping_method.origin_countries).not_to be_empty
        expect(shipping_method.international? || shipping_method.domestic?).to be true
      end
    end
  end

  describe 'rate_estimates' do
    let(:package) { FactoryBot.build(:physical_package) }
    let(:destination) { FactoryBot.build(:physical_location, region: "FL", zip: '32821') }
    let(:origin) { FactoryBot.build(:physical_location, region: "NC", zip: '27703') }
    let(:shipment) { FactoryBot.build(:physical_shipment, origin: origin, destination: destination) }

    subject { service.rate_estimates(shipment) }

    it 'returns Physical::Rate objects wrapped in a Success Monad', vcr: { cassette_name: 'ups/rate_estimates/success' } do
      aggregate_failures do
        is_expected.to be_success
        expect(subject.value!.data).to be_a(Array)
        expect(subject.value!.data.first).to be_a(FriendlyShipping::Rate)
      end
    end

    context 'if the origin has a wrong zipcode', vcr: { cassette_name: 'ups/rate_estimates/failure' } do
      let(:origin) { FactoryBot.build(:physical_location, zip: '78756') }

      it 'returns a Failure with the correct error message' do
        aggregate_failures do
          is_expected.to be_failure
          expect(subject.failure.to_s).to eq("Failure: The postal code 78756 is invalid for IL United States.")
        end
      end
    end
  end

  describe 'city_state_lookup' do
    subject { service.city_state_lookup(location) }

    context 'with a good ZIP code', vcr: { cassette_name: 'ups/city_state_lookup/success' } do
      let(:location) { Physical::Location.new(zip: '27587', country: 'US') }

      it { is_expected.to be_success }

      it 'has correct data' do
        result_data = subject.value!.data.first
        expect(result_data.city).to eq('WAKE FOREST')
        expect(result_data.region.code).to eq('NC')
      end
    end

    context 'with a ZIP code spanning multiple states', vcr: { cassette_name: 'ups/city_state_lookup/multiple_states' } do
      let(:location) { Physical::Location.new(zip: '81137', country: 'US') }

      it { is_expected.to be_success }

      it 'has correct data' do
        result_data = subject.value!.data.first
        # Even though this ZIP code DOES span two states, UPS returns Colorado.
        expect(subject.value!.data.length).to eq(1)
        expect(result_data.city).to eq('IGNACIO')
        expect(result_data.region.code).to eq('CO')
      end
    end

    context 'with a bad ZIP code', vcr: { cassette_name: 'ups/city_state_lookup/failure' } do
      let(:location) { Physical::Location.new(zip: '00000', country: 'US') }

      it { is_expected.to be_failure }

      it 'has a nice error message' do
        expect(subject.failure.to_s).to eq('Failure: The field, PostalCode, contains invalid data, 00000')
      end
    end
  end

  describe 'address_validation' do
    subject { service.address_validation(address) }

    context 'with a valid address', vcr: { cassette_name: 'ups/address_validation/valid_address' } do
      let(:address) do
        FactoryBot.build(
          :physical_location,
          name: "Dag Hammerskjöld",
          company_name: "United Nations",
          address1: "405 East 42nd Street",
          city: "New York",
          region: "NY",
          zip: "10017"
        )
      end

      it 'returns the address, upcased, in UPS standard form' do
        expect(subject).to be_success
        result_address = subject.value!.data.first
        expect(result_address.address1).to eq('405 E 42ND ST')
      end
    end

    context 'with an entirely invalid address', vcr: { cassette_name: 'ups/address_validation/invalid_address' } do
      let(:address) do
        FactoryBot.build(
          :physical_location,
          name: "Wat Wetlands",
          company_name: "Hogwarts School of Wizardry",
          address1: "Platform nine and a half",
          city: "New York",
          region: "NY",
          zip: "10017"
        )
      end

      it 'returns a failure indicating the address could not be validated' do
        expect(subject).to be_failure
      end
    end

    context 'with a slightly invalid address', vcr: { cassette_name: 'ups/address_validation/correctable_address' } do
      let(:address) do
        FactoryBot.build(
          :physical_location,
          name: "Dag Hammerskjöld",
          company_name: "United Nations",
          address1: "406 East 43nd Street",
          city: "New York",
          region: "NY",
          zip: "27777"
        )
      end

      it 'returns a corrected address' do
        is_expected.to be_success
        corrected_address = subject.value!.data.first
        expect(corrected_address.zip).to eq('10036-6322')
      end
    end

    context 'with an incomplete address', vcr: { cassette_name: 'ups/address_validation/incomplete_address' } do
      let(:address) do
        FactoryBot.build(
          :physical_location,
          name: "Dag Hammerskjöld",
          company_name: "United Nations",
          address1: "East 43nd Street",
          city: "New York",
          region: "NY",
          zip: "27777"
        )
      end

      it 'returns several alternatives' do
        is_expected.to be_success
        suggested_addresses = subject.value!.data
        expect(suggested_addresses.length).to eq(15)
        # All returned addresses need to have a first address line
        expect(suggested_addresses.map(&:address1).compact.length).to eq(15)
        # In this particular request, the last suggested address has a second address line.
        expect(suggested_addresses.last.address2).to eq("FRNT A-B")
      end
    end
  end

  describe '#labels' do
    let(:origin) do
      FactoryBot.build(
        :physical_location,
        name: 'John Doe',
        company_name: 'Company',
        address1: '10 Lovely Street',
        address2: 'Northwest',
        region: 'NC',
        city: 'Raleigh',
        zip: '27615'
      )
    end

    let(:shipper) do
      FactoryBot.build(
        :physical_location,
        name: 'Jane Doe',
        company_name: 'Company',
        address1: '10 Lovely Street',
        address2: 'Northwest',
        region: 'NC',
        city: 'Raleigh',
        zip: '27615'
      )
    end

    let(:destination) do
      FactoryBot.build(
        :physical_location,
        address1: '7007 Sea World Dr',
        city: 'Orlando',
        region: 'FL',
        zip: '32821'
      )
    end

    # UPS Ground is 03
    let(:shipping_method) { FriendlyShipping::ShippingMethod.new(service_code: '03') }
    let(:shipper_number) { ENV['UPS_SHIPPER_NUMBER'] }
    let(:shipment) { FactoryBot.build(:physical_shipment, origin: origin, destination: destination) }

    subject(:labels) { service.labels(shipment, options: options) }

    let(:options) do
      FriendlyShipping::Services::Ups::LabelOptions.new(
        shipping_method: shipping_method,
        shipper_number: shipper_number
      )
    end

    it 'returns labels along with the response', vcr: { cassette_name: "ups/labels/success" } do
      expect(subject).to be_a(Dry::Monads::Result)
      expect(subject.value!.data.length).to eq(2)
      expect(subject.value!.data.map(&:tracking_number)).to be_present
      expect(subject.value!.data.map(&:label_data).first.first(5)).to eq("GIF87")
      expect(subject.value!.data.map(&:label_format).first).to eq("GIF")
    end

    context "if the address is invalid", vcr: { cassette_name: "ups/labels/failure" } do
      let(:destination) do
        FactoryBot.build(
          :physical_location,
          address1: "x" * 36, # only 35 characters are allowed
          city: 'Orlando',
          region: 'FL',
          zip: '32821'
        )
      end

      it "returns a failure with a good error message" do
        is_expected.to be_failure
        expect(subject.failure.to_s).to eq("Failure: Missing or invalid ship to address line 1")
      end
    end
  end
end
