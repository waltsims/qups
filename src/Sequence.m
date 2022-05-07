classdef Sequence < handle
    % SEQUENCE - Class defining transmit sequences
    %
    % A SEQUENCE object defines the parameters for common transmit
    % sequences and is used to define beamforming delays. 
    %
    % The following properties must be set by the caller/construtor:
    %
    % properties
    %     type = 'FSA'            % {'FSA', 'plane[-wave]'], 'virtual[-source]']}
    %     focus = [0;0;0]         % (3 x S) array specifying the focal point or plane-wave direction (m)
    %     c0 = 1540               % sound speed for the transmit delays (m/s)
    %     pulse = Waveform.Delta()% ([1|N] x [1|S]) transmit Waveform (array)
    % end
    %
    % S -> number of transmitted pulses
    %
    % FSA -> Full synthetic aperture
    % PW  -> plane wave
    % VS  -> virtual source
    % 
    % The 'numPulse' property yields the value of S. However, for
    % full-synthetic-aperture sequences, this value is not known without
    % knowing the transducer, so it must be set manually with
    %
    % seq.numPulse = xdc.numel;
    %
    % See also: SEQUENCERADIAL
    
    properties
        type = 'FSA'            % {'FSA', 'PW', 'VS'}
        focus = [0;0;0]         % (3 x S) array specifying the focal point or plane-wave direction (m)
        c0 = 1540               % sound speed for the transmit delays (m/s)
        pulse = Waveform.Delta()% ([1|N] x [1|S]) transmit Waveform (array)
    end
    
    properties(Dependent)
        numPulse        % number of pulses: set manually if sequence.type == 'FSA'
    end
    
    properties(Hidden)
        FSA_n_tx = nan % hidden storage of the number of pulse for an FSA sequence
        apodization_ = [] % hidden storage of user entered apodization values or function
    end
    
    methods
        % constructor
        function self = Sequence(varargin)
            % SEQUENCE/SEQUENCE - Sequence constructor
            %
            % Uses name/value pair initialization
            %
            % 
            for i = 1:2:nargin, self.(varargin{i}) = varargin{i+1}; end
        end
    end
    
    % conversion methods
    methods
        function seq = getUSTBSequence(self, xdc, t0)
            % GETUSTBSEQUENCE - Get a USTB/UFF uff.sequence object
            %
            % seq = GETUSTBSEQUENCE(self, xdc, t0) creates a USTB
            % compatible sequence object from the QUPS Sequence object
            % where xdc is a QUPS transducer and t0 is the start time in
            % the QUPS coordinate system.
            %
            % See also Transducer/getUSTBProbe


            % initialize all wave objects
            N = self.numPulse;
            for n = N:-1:1, seq(n) = uff.wave(); end
            
            % set the common settings
            [seq.probe] = deal(xdc.getUSTBProbe());
            [seq.sound_speed] = deal(self.c0);
            
            switch self.type
                case {'PW'}
                    [seq.wavefront] = deal(uff.wavefront.plane);
                    theta = atan2(self.focus(1,:),self.focus(3,:));
                    phi   = atan2(self.focus(2,:),hypot(self.focus(1,:),self.focus(3,:)));
                    for n=1:N, seq(n).source = uff.point(...
                            'azimuth', theta(n), ...
                            'elevation', phi(n), ...
                            'distance', inf ...
                            );
                    end
                    [seq.delay] = deal(t0);
                    
                case {'FSA'}
                    p = xdc.positions();
                    [seq.wavefront] = deal(uff.wavefront.spherical);
                    for n=1:N, seq(n).source.xyz = p(:,n).'; end
                    for n=1:N, seq(n).delay = p(:,n)/self.c0 + t0; end
                    
                case {'VS'}
                    [seq.wavefront] = deal(uff.wavefront.spherical);
                    for n=1:N, seq(n).source.xyz = self.focus(:,n).'; end
                    [seq.delay] = deal(t0);
                    
            end
                
        end
    end
    
    % temporal response methods
    methods   
        function tau = delays(self, tx)
            % tau = DELAYS(self, tx)
            %
            % computes the steering delays for directing a transmitted beam
            % given a focal point and sound speed. Delays are given such
            % that for a fixed sound speed, t=0 is the time where all
            % method = focus -> all waves reach the focal point
            % method = diverge -> a wave from the focal point reaches the
            %                       element
            % method = plane -> the plane intersects the point [0;0;0]
            %
            % If using the plane wave method, the focal point is instead a
            % vector direction for the plane wave
            %
            % Inputs:
            % - tx:        a Transducer
            %
            % Outputs:
            %   - tau:      a (N x S) array of element delays (s)
            %
            % N -> number of elements, S -> number of transmits
            
            % element positions (3 x 1 x N)
            p = permute(tx.positions(),[1 3 2]); 
            
            switch self.type
                case 'VS'
                    v = self.focus - p; % element to focus vector (3 x S x N)
                    s = ~all(self.focus(3,:) > p(3,:,:), 3); % whether in behind of the transducer (1 x S)
                    tau = hypot(hypot(v(1,:,:), v(2,:,:)),v(3,:,:)) ./ self.c0; % delay magnitude (1 x S x N)
                    tau = (-1).^s .* tau; % swap sign for diverging transmit
                    
                case 'PW'
                    % use inner product of plane-wave vector with the
                    % positions to get plane-aligned distance
                    tau = sum(self.focus .* p, 1) ./ self.c0; % delay (1 x S x N)
                case 'FSA'
                    tau = zeros([1 size(p,3) size(p,3)]);
                otherwise
                    error('Reached an unexpected state :(');
            end
            
            % reshape for output
            tau = permute(tau, [3 2 1]);
        end

        function a = apodization(self, tx)
            if isempty(self.apodization_) % apodization not set by user:
                switch self.type
                    case 'FSA'
                        % TODO: use apodization as a sequence property?
                        a = eye(size(tx.positions(),2)); % N x N identity
                    otherwise
                        a = ones([size(tx.positions(),2) self.numPulse]); % N x S
                end
            else
                if isa(self.apodization_, 'function_handle')
                    a = self.apodization_(tx); % call the function on tx
                elseif isnumeric(self.apodization_)
                    a = self.apodization_; % return the user supplied values
                else, warning("Unable to interpret apodization; not a function handle or numeric type")
                    a = self.apodization_; % return the user supplied values anyway
                end
            end
        end

        function t0 = t0Offset(self)
            switch self.type
                case 'VS' % for virtual source, t0 is at the foci
                    t0 = - vecnorm(self.focus, 2,1) ./ self.c0; % (1 x S)
                otherwise % PW - t0 is at origin; FSA - t0 at the element
                    t0 = 0; % (1 x 1)
            end
        end
    end
    
    % get methods
    methods
        % number of transmit pulses 
        function v = get.numPulse(self)
            switch self.type
                case 'FSA'
                    v = self.FSA_n_tx;
                otherwise
                    v = size(self.focus, 2);
            end
        end
        
        function set.numPulse(self, n)
            self.FSA_n_tx = n;
        end
       
        function setApodization(self, apod)
            % no halp :(
            
            % should be fun or data
            if ~(isa(apod, 'function_handle') || isnumeric(apod))
                warning("Expected a function handle or numeric type; instead got a " + class(apod) + ".");
            end
            self.apodization_ = apod; 
        end
        
        % set the transmit type
        function set.type(self, t)
            switch t
                case {'PW','FSA','VS'}
                    self.type = t;
                otherwise
                    error('UltrasoundSystem:Sequence:ArgumentError', 'Unknown sequence type');
            end
        end
        
        % set the focal points
        function set.focus(self, f)
            assert(size(f,1)==3, 'The focus must be a (3 x S) vector')
            self.focus = f;
        end
        function f = get.focus(self)
            if any(ismember(self.type, ["FSA", "full-synthetic-aperture"]))
                f = zeros([3,0]);
            else
                f = self.focus;
            end
        end
    end

    % plotting methods
    methods
        function h = plot(self, varargin)
            if nargin >= 2 && isa(varargin{1}, 'matlab.graphics.axis.Axes') % determine the axis
                hax = varargin{1}; varargin(1) = []; % delete this input
            else 
                hax = gca;
            end

            switch self.type
                case{'PW',}
                    % make a quiver plot, starting at the origin, and
                    % pointing in the vector direction
                    [x, y] = deal(zeros([1, self.numPulse]));
                    [u, v] = deal(self.focus(1,:), self.focus(3,:));
                    h = quiver(hax, x, y, u, v, varargin{:});
                otherwise
                    % plot the positions with the options given in the inputs
                    h = plot(hax, self.focus(1,:), self.focus(3,:), varargin{:});
            end
        end
    end
end
