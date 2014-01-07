Pod::Spec.new do |s|
  s.name = 'FCOfflineQueue'
  s.version = '0.1.0'
  s.summary = 'Serial iOS operation queue that pauses when offline and persists unfinished operations between launches.'
  s.homepage = 'https://github.com/marcoarment/FCOfflineQueue'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'Marco Arment' => 'arment@marco.org' }
  s.source = { :git => 'https://github.com/marcoarment/FCOfflineQueue.git', :tag => s.version.to_s }
  s.source_files  = 'FCOfflineQueue/*.{h,m}'
  s.library = 'sqlite3'
  s.requires_arc = true
  s.dependency 'FMDB', '~> 2.1'
  s.dependency 'FCUtilities'
  s.ios.deployment_target = '7.0'
end
