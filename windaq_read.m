function wdq = windaq_read(filename)
    % This will (at least attempt to) read a windaq file. 
    % 
    % Based on:
    %   https://www.dataq.com/resources/pdfs/misc/ff.pdf
    %
    % I also referenced nReadDataq.m from the mathworks file exchange
    % 
    % Inputs:
    %   filename - string; name of windaq file to be read
    %   
    % Outputs:
    %   wdq - structure; contains:
    %       .header (cell)
    %       .data (struct)
    %           .val  (cell)
    %           .meta (cell)
    %       .trailer (struct)
    %           .event_markers (struct)
    %               .pointer     (scalar)
    %               .time_stamp  (scalar)
    %               .comment     (char)
    %           .annotations (cell)

    % NOTES: Confirmed with dataq that:
    %   1) ints and longs are stored little-endian
    %   2) signed integers are twos-complement
    %   3) "B" in the documentation is always unsigned EXCEPT for header
    %       element #24 and channel header element #5 
    
    % TODO: add FBS grant support info

    % Initialize structure
    wdq = struct('header',[],'data',[],'trailer',[]);
    
    % Open file ----------------------------------------------------------%
    disp(['Reading windaq file: ' filename]);
    fid = fopen(filename,'r','ieee-le');

    % Read header first; header has 35 elements --------------------------%
    disp('---');
    disp('Reading header...');    
    wdq.header = {};

    % #1 (0-1) - total channels enabled - based on element 5, so come back 
    % to this and convert it to total channels enabled
    wdq.header{1} = fread(fid,1,'*uint16'); 

    % #2 (2-3) - Number of A/D Readings per sample.
    wdq.header{2} = fread(fid,1,'uint16');

    % #3 (4) - Offset in bytes from BOF to header channel info tables
    wdq.header{3} = fread(fid,1,'uint8');

    % #4 (5) - Number of bytes in each channel info entry
    wdq.header{4} = fread(fid,1,'uint8');

    % #5 (6-7) - Number of bytes in data file header
    wdq.header{5} = fread(fid,1,'int16');

    % Fix #1
    if wdq.header{5} == 1156
        % max channels is 29; Get the 5-bit hex value. According to the
        % documentation, we just need to clear out the 6th bit.
        wdq.header{1} = double(bitset(wdq.header{1},6,0));
    else
        % max channels is (wdq.header{5}-112)/36. According to the 
        % documentation, we just need to clear out the 9th bit.
        wdq.header{1} = double(bitset(wdq.header{1},9,0));
    end
    disp(['Total channels: ' num2str(wdq.header{1})]);

    % #6 (8-11) - for:
    %   Unpacked Files: Number of ADC data bytes in file excluding header
    %   Packed Files: Number of data bytes the file would have if it were
    %       unpacked.
    wdq.header{6} = fread(fid,1,'uint32');

    % #7 (12-15) - Total number of event marker, time and date stamp, and 
    % event marker comment pointer bytes in trailer
    wdq.header{7} = fread(fid,1,'uint32');

    % #8 (16-17) - Total number of user annotation bytes including 1 null 
    % per channel
    wdq.header{8} = fread(fid,1,'uint16');

    % #9 (18-19) - Header of graphics area in pixels. The data type is not
    % specified, so just skip it
    fseek(fid,2,'cof');

    % #10 (20-21) - Width of graphics are in pixels. The data type is not
    % specified, so just skip it
    fseek(fid,2,'cof');

    % #11 (22-23) - Cursor position relative to screen center
    wdq.header{11} = fread(fid,1,'int16');

    % #12 (24-27) -
    %   Byte 24: Max number of overlapping waveforms per window
    %   Byte 25: Max number of horizontal adjacent waveform windows
    %   Byte 26: Max number of vertically adjacent waveform windows
    %   Byte 27: "Reserved"
    wdq.header{12} = fread(fid,4,'uint8');

    % #13 (28-35) - Time between channel samples
    %   1/(sample rate throughput/total number of acquared channels)
    wdq.header{13} = fread(fid,1,'double');

    % #14 (36-39) - Time file was opened by acquisition (total number of
    % seconds since Jan. 1, 1970)
    wdq.header{14} = fread(fid,1,'int32');

    % #15 (40-43) - Time file trailer was written by acquisition (total 
    % number of seconds since Jan. 1,1970)
    wdq.header{15} = fread(fid,1,'int32');

    % #16 (44-47) - Waveform compression factor
    wdq.header{16} = fread(fid,1,'int32');

    % #17 (48-51) - Position of cursor in waveform file
    wdq.header{17} = fread(fid,1,'int32');

    % #18 (52-55) - Position of time marker in waveform file
    wdq.header{18} = fread(fid,1,'int32');

    % TODO: 19 is a little unclear from the documentation

    % #19 (56-59) -
    %   Bytes 56-57: Number of pretrigger data points
    %   Bytes 58-59: Number of posttrigger data points
    wdq.header{19} = fread(fid,1,'*int32'); 
    wdq.header{19} = [bi2de(logical(bitget(wdq.header{19},1:16))) bi2de(logical(bitget(wdq.header{19},17:32)))];

    % #20 (60-61) - Position of left limit cursor from screen-center in 
    % pixels
    wdq.header{20} = fread(fid,1,'int16');

    % #21 (62-63) - Position of right limit cursor from screen-center in 
    % pixels
    wdq.header{21} = fread(fid,1,'int16');

    % #22 (64) - Playback state memory
    %   bit 0: Cursor on/off
    %   bit 1: waveform values on/off
    %   bit 2: TBF function on/off
    %   bit 3: time marker on/off
    %   bit 4: %EOF on/off
    %   bit 5: base line mode on/off 
    %   bit 6: scroll lock on/off
    %   bit 7: event markers on/off
    wdq.header{22} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % #23 (65) - Grid, annotation, and compression mode
    %   bit 0 = 1 if grid pattern is enabled
    %   bit 1 = 1 if user annotation is enabled
    %   bit 2-3 determine annotation state
    %   bit 4-5 determine compression mode
    %   bit 6-7 are reserved and must be zero
    wdq.header{23} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % NOTE: #24 is a signed byte
    
    % #24 (66) - Channel number enabled for adjustments.
    %   0 = channel1
    %   -1 = none
    wdq.header{24} = fread(fid,1,'int8');

    % #25 (67) - Scroll, 'T' key, 'P' key, and 'W' key states
    %   bit 0-3: (P)alette state
    %   bit 4-5: File display state
    %   bit 6: 1 if last scroll direction was reverse
    %   bit 7: 1 if (W)indow-oriented scroll mode is enabled
    wdq.header{25} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % #26 (68-99) - Array of 32 elements describing the channels assigned 
    % to each waveform window. 
    wdq.header{26} = fread(fid,32,'uint8');

    % TODO: Documentation doesn't appear to state what bit 0 does for #27!

    % #27 (100-101) - 
    %   bit 0: ?
    %   bit 1: 1 specifies HiRes file with 16-bit data
    %   bit 2-3: thermocouple type
    %   bit 4-7: 
    %       Standard version: reserved and must be 0
    %       Multiplexer version: most significant 4 bits of trigger channel
    %           number
    %   bit 8: 1 if Oscilloscope Mode's "Free Run" box is checked
    %   bit 9: 1 if lowest physical channel number is 0 instead of 1
    %   bit 10-11: F3 key selection
    %   bit 12-13: F4 key selection
    %   bit 14: 1 if file is packed
    %   bit 15: 1 display FFT in magnitude; 0 display FFT in db
    wdq.header{27} = logical(bitget(fread(fid,1,'*uint16'),1:16));

    % #28 (102) -
    %   bit 0-12: lowest frequency index on the display
    %   bit 13: FFT type
    %   bit 14-15: Window type
    wdq.header{28} = logical(bitget(fread(fid,1,'*uint16'),1:16));

    % TODO: I'm assuming bits 0-3 and bits 4-7 get converted to a decimal 
    % in #29

    % #29 (104) - 
    %   bit 0-3: define magnification factor applied to spectrum
    %   bit 4-7: define the spectrum moving average factor
    wdq.header{29} = fread(fid,1,'*uint8'); 
    wdq.header{29} = [bi2de(logical(bitget(wdq.header{29},1:4))) bi2de(logical(bitget(wdq.header{29},5:8)))];

    % #30 (105) - 
    %   bit 0-3: define trigger channel source
    %   bit 4: 1/0, erase bar on/off
    %   bit 5-6: Display mode
    %   bit 7: trig sweep slope
    wdq.header{30} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % #31 (106-107) - 
    %   bit 0 - set to indicated Triggered Mode
    %   bit 1 - set to indicate Triggered Storage Mode
    %   bit 2-15 - describe the Triggered sweep level
    wdq.header{31} = logical(bitget(fread(fid,1,'*int16'),1:16));

    % TODO: documentation doesn't specify what bit 5 does for #32

    % #32 (108) - 
    %   bit 0-4 - describe the number of 1/16th XY screen stripes enabled 
    %       (0-16)
    %   bit 5 - ?
    %   bit 6-7 - describe the active XY cursor
    wdq.header{32} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % # 33 (109) - 
    %   bit 0-3 - specify Triggered Mode Hysteresis
    %   bit 4 - 1 if remote events enabled
    %   bit 5 - 1 if remote storage enabled
    %   bit 6 - 1/0 events triggered on -/+ slope
    %   bit 7 - 1/0 storage triggered on -/+ slope
    wdq.header{33} = logical(bitget(fread(fid,1,'*uint8'),1:8));

    % Perform check to make sure offset is equal to to header element{3}
    if ftell(fid) ~= wdq.header{3}
        error(['file pointer offset: ' num2str(ftell(fid)) ' doesnt match 3rd ' ...
               'element of header file: ' num2str(wdq.header{3}) '! Please make ' ...
               'sure input file is really a windaq file. If input file is a ' ...
               'valid windaq file, please update the code.']);
    else
        disp(['Check passed: file pointer offset matches 3rd element of ' ...
              'header file: ' num2str(wdq.header{3}) '. Header up to channel ' ...
              'info tables should be loaded correctly.']);
    end

    % # 34 (110 to wdq.header{5}-3) - Channel information
    channel_headers = {};
    max_channels = (wdq.header{5}-112)/wdq.header{4};
    for pointer_idx = 1:max_channels
        % 1 - scaling slope (m) applied to the waveform to scale it within 
        % the display window.
        channel_header{1} = fread(fid,1,'float');

        % 2 - scaling intercept value (b) to item 1
        channel_header{2} = fread(fid,1,'float');

        % 3 - Calibration scaling factor (m) for waveform value display
        channel_header{3} = fread(fid,1,'double');

        % 4 - Calibration intercept factor (b) for waveform value display
        channel_header{4} = fread(fid,1,'double');

        % NOTE: #5 is a signed byte
        
        % 5 - Engineering units tag for calibrated waveform - note that
        % although 6 bytes are reserved, only four are used for an 
        % engineering unit tag
        channel_header{5} = fread(fid,6,'int8=>char');
        channel_header{5} = channel_header{5}(1:4)';

        % 6 - reserved
        fseek(fid,1,'cof');

        % 7 - 
        %   unpacked files: reserved
        %   packed files: sample rate divisor for the channel
        if wdq.header{27}(15)
            % packed        
            channel_header{7} = fread(fid,1,'uint8');
        else
            % unpacked
            fseek(fid,1,'cof');
        end

        % TODO: #8 does not entirely make sense to me; recheck this in the
        % future.

        % 8 - 6 bits (standard version) or 8 bits (multiplexer versions) 
        % used to describe the physical channel number referred to the 
        % input.
        channel_header{8} = fread(fid,1,'uint8');

        % TODO: possibly convert these values to those specified by the
        % documentation (i.e. convert gain value of 11 to its true value of
        % 200).

        % 9 - Specifies Gain, mV Full Scale, and Unipolar/Bipolar    
        %   bit 0-3 - gain
        %   bit 4-7 - full scale value in millivotes 
        channel_header{9} = fread(fid,1,'*uint8'); 
        channel_header{9} = [bi2de(logical(bitget(channel_header{9},1:4))) bi2de(logical(bitget(channel_header{9},5:8)))];

        % 10 -
        %   bit 0-4 - reserved and must be zero
        %   bit 5-7 - specify thermocouple type
        %   bit 8-10 - define acquisition method
        %   bit 11 - set for last point to disable averaging
        %   bit 12 - set for nonlinear, non-thermocouple channels
        %   bit 13 - set for digital input channels
        %   bit 14 - set to enable Scaling Digital Plot on a digital 
        %       channel (standard version) or is set for differential 
        %       channels (multiplexer versions)
        %   bit 15 - set for thermocouple channels
        channel_header{10} = logical(bitget(fread(fid,1,'*uint16'),1:16));

        % Store
        channel_headers{pointer_idx} = channel_header; %#ok<AGROW>
    end
    wdq.header{34} = channel_headers;

    % #35 (wdq.header{5}-2 to wdq.header{5}-1) - Fixed value of 8001H
    wdq.header{35} = fread(fid,1,'*int16');

    % Perform check to make sure wdq.header{35} is 8001H
    if wdq.header{35} ~= int16(-32767)
        error(['windaq header element 35: ' num2str(wdq.header{35}) ' is not '...
               'equal to 8001H. Please make sure input file is really a ' ...
               'a windaq file. If input file is a valid windaq file, please '...
               'update the code.']);
    else
        disp('Check passed: windaq header element 35 is correctly equal to 8001H');
    end

    % Perform check to make sure offset is equal to header element{5}
    if ftell(fid) ~= wdq.header{5}
        error(['file pointer offset: ' num2str(ftell(fid)) ' doesnt match 5th ' ...
               'element of header file: ' num2str(wdq.header{5}) '! Please make ' ...
               'sure input file is really a windaq file. If input file is a ' ...
               'valid windaq file,  please update the code.']);
    else
        disp(['Check passed: file pointer offset matches 5th element of ' ...
              'header file: ' num2str(wdq.header{5}) '. Header should be ' ...
              'loaded correctly.']);
    end

    % Read ADC data ------------------------------------------------------%
    % Each "recorded value" is a 16-bit word: 
    %   if windaq file is "HiRes": all bits are data
    %   else: the 2 LSB are meta data, and a right bit shift must be 
    %       applied to get the data values
    %
    % All data must be multiplied by the slope (#3 of channel header) and 
    % intercept (#4 of channel header) to bring values to channel's 
    % engineering unit (#5 of channel header) 

    % TODO: It's not exactly clear from the documentation how to read 
    % packed files that have channels with different sample rate divisors 
    % (if this is even allowable). If this results in non-evenly 
    % interleaved data points then I will not be able to use the default
    % fread() with spaces, which would make this function very slow and 
    % almost  unusable, so just don't worry about it for now.
    disp('---');
    disp('Reading data...');

    wdq.data.val = {};
    wdq.data.meta = {};
    num_samples = zeros(1,wdq.header{1});
    for pointer_idx = 1:wdq.header{1}
        disp(['Reading channel ' num2str(pointer_idx) ' of ' num2str(wdq.header{1}) '...']);
        
        % Data is interleaved, so seek to the proper position
        fseek(fid,wdq.header{5}+2*(pointer_idx-1),'bof');

        % Set the number of samples
        if wdq.header{27}(15)
            % packed      
            num_samples(pointer_idx) = (((wdq.header{6}/(2*wdq.header{1}))-1)/wdq.header{34}{pointer_idx}{7})+1;
        else
            % unpacked
            num_samples(pointer_idx) = wdq.header{6}/(2*wdq.header{1});
        end

        % Read data
        wdq.data.val{pointer_idx} = fread(fid,num_samples(pointer_idx),'*int16',2*(wdq.header{1}-1));

        % Prepare data before scaling and intercepts are applied; Also get 
        % data meta data (the 2 LSB)
        if wdq.header{27}(2)
            % "HiRes" data
            
            % TODO: The 2 LSB are supposed to be part of the actual data;
            % hence the "HiRes". I've made the assumption that this data
            % does not have any meta data.
            
            % multiple by 0.25
            wdq.data.val{pointer_idx} = double(wdq.data.valdata{pointer_idx})*0.25; 
        else
            % Get data meta data first; Grab the 2 LSB by doing a left bit
            % shift of 14, followed by a right bit shift of 14. I've done
            % this because it appears the bitget() operator is not
            % vectorized. This converts the following to:
            %   [0 0] =>  0 - default state of all channels except
            %       lowest-numbered acquired channel
            %   [0 1] =>  1 - default state of lowest-number acquired
            %       channel
            %   [1 0] => -2 - displays a negative-going marker on any
            %       channel's waveform
            %   [1 1] => -1 - displays a positive-going marker on any
            %       channel's waveform
            % 
            % So, for example, if you want to find the positive-going
            % markers just find the elements equal to -1 in data_meta
            wdq.data.meta{pointer_idx} = double(bitshift(bitshift(wdq.data.val{pointer_idx},14),-14));
            
            % Apply bitshift twice to the right
            wdq.data.val{pointer_idx} = double(bitshift(wdq.data.val{pointer_idx},-2));
        end

        % TODO: There are two scaling factors and two intercepts in the 
        % channel header. I'm assuming #3 and #4 are the "m" and "b" we 
        % want for the data to be in engineering units.
        
        % Apply slope and intercept
        wdq.data.val{pointer_idx} = wdq.header{34}{pointer_idx}{3}*wdq.data.val{pointer_idx}+wdq.header{34}{pointer_idx}{4};
        
        % Check to see if all num_samples are the same
        if length(unique(num_samples(1:pointer_idx))) ~= 1
            error(['Number of samples was found to change per channel. ' ...
                   'Number of samples up to this point was found to be: ' ... 
                   num2str(num_samples(1:pointer_idx)) '. This is not currently ' ...
                   'supported.']);
        end
    end
       
    % Get total number of bytes
    if wdq.header{27}(15)
        % packed      
        total_bytes = 2*sum(num_samples);
    else
        % unpacked
        total_bytes = wdq.header{6};
    end
    
    % Seek back to beginning of data trailer
    fseek(fid,-2*(wdq.header{1}-1),'cof');
        
    % Perform check to make sure offset is equal to beginning of data
    % trailer
    if ftell(fid) ~= total_bytes + wdq.header{5}
        error(['file pointer offset: ' num2str(ftell(fid)) ' doesnt match ' ...
               'beginning of data trailer: ' num2str(total_bytes + wdq.header{5}) ...
               '! Please make sure input file is really a windaq file. ' ...
               'If input file is a valid windaq file, please update the ' ...
               'code.']);
    else
        disp(['Check passed: file pointer offset matches beginning of ' ...
              'data trailer: ' num2str(total_bytes + wdq.header{5}) '. Data ' ...
              'should be loaded correctly.']);
    end
        
    % Read trailer -------------------------------------------------------%
    disp('---');
    disp('Reading trailer...');
    
    % Read all pointers
    pointers = fread(fid,wdq.header{7}/4,'*int32');
    
    % TODO: not quite sure if this section is correct for packed/"HiRes" 
    % windaq files
    
    % Handle event markers first
    disp('Reading event markers...');
    event_marker_idx = 1;
    pointer_idx = 1;
    while pointer_idx <= wdq.header{7}/4        
        % Get pointer
        pointer = pointers(pointer_idx);
        pointer_idx = pointer_idx + 1;
        
        % Get time_stamp
        if pointer_idx <= wdq.header{7}/4 && pointer >= 0
            % time_stamp exists, grab it directly
            time_stamp = double(pointers(pointer_idx));
            pointer_idx = pointer_idx + 1;
        else            
            % time_stamp doesn't exist; get this based on the previous
            % marker location, time_stamp and channel sample rate
            time_stamp = (double(abs(pointer)+1)-wdq.trailer.event_markers(event_marker_idx-1).pointer)*wdq.header{13} + ...
                          wdq.trailer.event_markers(event_marker_idx-1).time_stamp;
        end
           
        % Get comment
        if (pointer_idx <= wdq.header{7}/4 && ~wdq.header{27}(2) && pointers(pointer_idx) <= -1*(wdq.header{6}/(2*wdq.header{1}))) || ... % non "HiRes" 
           (pointer_idx <= wdq.header{7}/4 && wdq.header{27}(2) && pointers(pointer_idx) <= -1*(wdq.header{6}/2))                         % "HiRes" 
            % comment pointer exists; must do a bit-wise AND with 7FFFFFFF             
            comment_pointer = bitand(pointers(pointer_idx),int32(2147483647));
            pointer_idx = pointer_idx + 1;
            
            % Store pointer
            comment = comment_pointer;
        else
            % Store -1 to indicate no comment exists
            comment = int32(-1);
        end
        
        % Store
        wdq.trailer.event_markers(event_marker_idx).pointer = double(abs(pointer)+1);
        wdq.trailer.event_markers(event_marker_idx).time_stamp = time_stamp;
        wdq.trailer.event_markers(event_marker_idx).comment = comment;
            
        % Increment event marker inx
        event_marker_idx = event_marker_idx + 1;
    end
    
    % Convert comment pointers into comments
    for i = 1:length(wdq.trailer.event_markers)
        comment_pointer = wdq.trailer.event_markers(i).comment;
        if comment_pointer == int32(-1)
            wdq.trailer.event_markers(i).comment = '';
        else
            % Seek to offset => read comment and store it => seek back
            fseek(fid,comment_pointer,'cof');
            
            % TODO: see if there's matlab functionality to read until NULL
            % character is encountered
            
            % read comment
            comment = '';
            comment_length = 0;
            while true
                character = fread(fid,1,'int8=>char');
                comment_length = comment_length + 1;
                % Break if null character encountered
                if character == char(0)
                    break
                else
                    comment = [comment character]; %#ok<AGROW>
                end
            end
            wdq.trailer.event_markers(i).comment = comment;
            
            % Now seek back
            fseek(fid,-(comment_pointer+comment_length),'cof');          
        end        
    end
    disp([num2str(length(wdq.trailer.event_markers)) ' event markers found.']);
    
    % Read all annotations; split based on null character
    disp('Reading event markers...');
    if wdq.header{8} > 0
        % Read all annotations
        wdq.trailer.annotations = fread(fid,wdq.header{8},'int8=>char');
        
        % Split by null character (every annotation is null character
        % terminated)
        wdq.trailer.annotations = strsplit(wdq.trailer.annotations',char(0));
        
        % Remove last entry since this will be empty
        wdq.trailer.annotations(end) = [];        
    end
    disp([num2str(length(wdq.trailer.annotations)) ' annotations found.']);
    
    % Finished!
    disp('---');
    disp('Finished reading windaq file!');
    
    % Close file
    fclose(fid);
end
