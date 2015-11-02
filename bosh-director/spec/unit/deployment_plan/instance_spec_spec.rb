require 'spec_helper'

module Bosh::Director::DeploymentPlan
  describe InstanceSpec do
    include Support::StemcellHelpers
    subject(:instance_spec) { described_class.create_from_instance_plan(instance_plan)}
    let(:job_spec) { {name: 'job', release: 'release', templates: []} }
    let(:packages) { {'pkg' => {'name' => 'package', 'version' => '1.0'}} }
    let(:properties) { {'key' => 'value'} }
    let(:reservation) { Bosh::Director::DesiredNetworkReservation.new_dynamic(instance, network) }
    let(:network_spec) { {'name' => 'default', 'cloud_properties' => {'foo' => 'bar'}, 'availability_zone' => 'foo-az'} }
    let(:network) { DynamicNetwork.parse(network_spec, [AvailabilityZone.new('foo-az', {})], logger) }
    let(:job) {
      job = instance_double('Bosh::Director::DeploymentPlan::Job',
        name: 'fake-job',
        spec: job_spec,
        canonical_name: 'job',
        instances: ['instance0'],
        default_network: {},
        vm_type: vm_type,
        stemcell: stemcell,
        env: env,
        package_spec: packages,
        persistent_disk_type: disk_pool,
        can_run_as_errand?: false,
        link_spec: 'fake-link',
        compilation?: false,
        properties: properties)
    }
    let(:index) { 0 }
    let(:instance) { Instance.create_from_job(job, index, 'started', plan, {}, availability_zone, logger) }
    let(:vm_type) { VmType.new({'name' => 'fake-vm-type'}) }
    let(:availability_zone) { Bosh::Director::DeploymentPlan::AvailabilityZone.new('foo-az', {'a' => 'b'}) }
    let(:stemcell) { make_stemcell({:name => 'fake-stemcell-name', :version => '1.0'}) }
    let(:env) { Env.new({'key' => 'value'}) }
    let(:plan) do
      instance_double('Bosh::Director::DeploymentPlan::Planner', {
          name: 'fake-deployment',
          model: deployment,
        })
    end
    let(:deployment) { Bosh::Director::Models::Deployment.make(name: 'fake-deployment') }
    let(:instance_model) { Bosh::Director::Models::Instance.make(deployment: deployment, bootstrap: true, uuid: 'uuid-1') }
    let(:instance_plan) { InstancePlan.new(existing_instance: nil, desired_instance: DesiredInstance.new(job), instance: instance) }
    let(:disk_pool) { instance_double('Bosh::Director::DeploymentPlan::DiskType', disk_size: 0, spec: disk_pool_spec) }
    let(:disk_pool_spec) { {'name' => 'default', 'disk_size' => 300, 'cloud_properties' => {}} }

    before do
      reservation = Bosh::Director::DesiredNetworkReservation.new_dynamic(instance, network)
      instance_plan.network_plans << NetworkPlanner::Plan.new(reservation: reservation)
      instance.bind_existing_instance_model(instance_model)
    end

    describe '#apply_spec' do
      it 'returns a valid instance apply_spec' do
        network_name = network_spec['name']
        spec = instance_spec.as_apply_spec
        expect(spec['deployment']).to eq('fake-deployment')
        expect(spec['job']).to eq(job_spec)
        expect(spec['index']).to eq(index)
        expect(spec['networks']).to include(network_name)

        expect_dns_name = "#{index}.fake-job.#{network_name}.fake-deployment.bosh"
        expect(spec['networks'][network_name]).to eq({
            'type' => 'dynamic',
            'cloud_properties' => network_spec['cloud_properties'],
            'dns_record_name' => expect_dns_name
            })

        expect(spec['vm_type']).to eq(vm_type.spec)
        expect(spec['stemcell']).to eq(stemcell.spec)
        expect(spec['env']).to eq(env.spec)
        expect(spec['packages']).to eq(packages)
        expect(spec['persistent_disk']).to eq(0)
        expect(spec['configuration_hash']).to be_nil
        expect(spec['dns_domain_name']).to eq('bosh')
        expect(spec['id']).to eq('uuid-1')
      end

      it 'includes rendered_templates_archive key after rendered templates were archived' do
        instance.rendered_templates_archive =
          Bosh::Director::Core::Templates::RenderedTemplatesArchive.new('fake-blobstore-id', 'fake-sha1')

        expect(instance_spec.as_apply_spec['rendered_templates_archive']).to eq(
            'blobstore_id' => 'fake-blobstore-id',
            'sha1' => 'fake-sha1',
          )
      end

      it 'does not include rendered_templates_archive key before rendered templates were archived' do
        expect(instance_spec.as_apply_spec).to_not have_key('rendered_templates_archive')
      end

      it 'does not require persistent_disk_type' do
        allow(job).to receive(:persistent_disk_type).and_return(nil)

        spec = instance_spec.as_apply_spec
        expect(spec['persistent_disk']).to eq(0)
        expect(spec['persistent_disk_pool']).to eq(nil)
      end
    end


    describe '#template_spec' do
      it 'returns a valid instance template_spec' do
        network_name = network_spec['name']
        instance.bind_unallocated_vm
        spec = instance_spec.as_template_spec
        expect(spec['deployment']).to eq('fake-deployment')
        expect(spec['job']).to eq(job_spec)
        expect(spec['index']).to eq(index)
        expect(spec['networks']).to include(network_name)

        expect_dns_name = "#{index}.fake-job.#{network_name}.fake-deployment.bosh"
        expect(spec['networks'][network_name]).to include(
            'type' => 'dynamic',
            'cloud_properties' => network_spec['cloud_properties'],
            'dns_record_name' => expect_dns_name
          )

        expect(spec['vm_type']).to eq(vm_type.spec)
        expect(spec['stemcell']).to eq(stemcell.spec)
        expect(spec['env']).to eq(env.spec)
        expect(spec['packages']).to eq(packages)
        expect(spec['persistent_disk']).to eq(0)
        expect(spec['persistent_disk_pool']).to eq(disk_pool_spec)
        expect(spec['configuration_hash']).to be_nil
        expect(spec['properties']).to eq(properties)
        expect(spec['dns_domain_name']).to eq('bosh')
        expect(spec['links']).to eq('fake-link')
        expect(spec['id']).to eq('uuid-1')
        expect(spec['availability_zone']).to eq('foo-az')
        expect(spec['bootstrap']).to eq(true)
      end

      it 'does not require persistent_disk_pool' do
        allow(job).to receive(:persistent_disk_type).and_return(nil)

        spec = instance_spec.as_template_spec
        expect(spec['persistent_disk']).to eq(0)
        expect(spec['persistent_disk_pool']).to eq(nil)
      end

      context 'when persistent disk type' do
        let(:job) {
          job = instance_double('Bosh::Director::DeploymentPlan::Job',
            name: 'fake-job',
            spec: job_spec,
            canonical_name: 'job',
            instances: ['instance0'],
            default_network: {},
            vm_type: vm_type,
            stemcell: stemcell,
            env: env,
            package_spec: packages,
            persistent_disk_type: disk_type,
            can_run_as_errand?: false,
            link_spec: 'fake-link',
            compilation?: false,
            properties: properties)
        }
        let(:disk_type) { instance_double('Bosh::Director::DeploymentPlan::DiskType', disk_size: 0, spec: disk_type_spec) }
        let(:disk_type_spec) { {'name' => 'default', 'disk_size' => 400, 'cloud_properties' => {}} }

        it 'returns a valid instance template_spec' do
          network_name = network_spec['name']
          spec = instance_spec.as_template_spec
          expect(spec['deployment']).to eq('fake-deployment')
          expect(spec['job']).to eq(job_spec)
          expect(spec['index']).to eq(index)
          expect(spec['networks']).to include(network_name)

          expect_dns_name = "#{index}.fake-job.#{network_name}.fake-deployment.bosh"

          expect(spec['networks'][network_name]).to eq({
            'type' => 'dynamic',
            'cloud_properties' => network_spec['cloud_properties'],
            'dns_record_name' => expect_dns_name
          })

          expect(spec['vm_type']).to eq(vm_type.spec)
          expect(spec['stemcell']).to eq(stemcell.spec)
          expect(spec['env']).to eq(env.spec)
          expect(spec['packages']).to eq(packages)
          expect(spec['persistent_disk']).to eq(0)
          expect(spec['persistent_disk_type']).to eq(disk_type_spec)
          expect(spec['configuration_hash']).to be_nil
          expect(spec['properties']).to eq(properties)
          expect(spec['dns_domain_name']).to eq('bosh')
          expect(spec['links']).to eq('fake-link')
          expect(spec['id']).to eq('uuid-1')
          expect(spec['availability_zone']).to eq('foo-az')
          expect(spec['bootstrap']).to eq(true)
        end

        it 'does not require persistent_disk_type' do
          allow(job).to receive(:persistent_disk_type).and_return(nil)

          spec = instance_spec.as_template_spec
          expect(spec['persistent_disk']).to eq(0)
          expect(spec['persistent_disk_type']).to eq(nil)
        end
      end
    end
  end
end
