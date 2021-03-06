 //
//  MAMPCHandler.m
//  MultiChat
//
//  Created by Donald Pae on 5/21/14.
//  Copyright (c) 2014 donald. All rights reserved.
//

#import "MAMPCHandler.h"
#import "MAGlobalData.h"


@interface MAMPCHandler() {
    BOOL _isStarted;
    BOOL _isConnected;
    
    NSString *_advertisingPeer;
    BOOL _isInvited;
    
    NSTimer *_timer;
    int _lastTime;
    int _interval;
    
    int _lastInviteTime;
    int _lastFoundPeerTime;
    
    NSMutableArray *_invitingPeers;
    
    
    BOOL _isAdvertising;
}

@property (nonatomic, strong) MAPeerID *peerID;
@property (nonatomic, strong) MCSession *session;
@property (nonatomic, strong) MCNearbyServiceBrowser *browser;
@property (nonatomic, strong) MCNearbyServiceAdvertiser *advertiser;

@property (nonatomic, strong) NSRecursiveLock *theLock;
@property (nonatomic, strong) NSRecursiveLock *delegateLock;


// user to store messages
// {    key     : value }
// { sender uid : array of MAMessage}
@property (nonatomic, strong) NSMutableDictionary *messages;

@property (nonatomic, strong) NSMutableDictionary *peers;



@end

@implementation MAMPCHandler

- (id)init{
    self = [super init];
    
    self.theLock = [[NSRecursiveLock alloc] init];
    self.delegateLock = [[NSRecursiveLock alloc] init];
    
    _isStarted = NO;
    _isConnected = NO;
    
    self.messages = [[NSMutableDictionary alloc] init];
    self.peers = [[NSMutableDictionary alloc] init];
    
    _invitingPeers = [[NSMutableArray alloc] init];
    
    
    return self;
}

- (void)setDelegate:(id<MAMPCHandlerDelegate>)delegate
{
    [self.delegateLock lock];
    _delegate = delegate;
    [self.delegateLock unlock];
}


- (void)start:(NSString *)displayName {
    [self.theLock lock];
    
    _isConnected = NO;
    _advertisingPeer = nil;
    [_invitingPeers removeAllObjects];

    [self setupPeerWithDisplayName:displayName];
    
    [self setupSession];
    [self startAdvertiser];
    [self startBrowser];

    NSLog(@"handler started");
    
    _isStarted = YES;
    
    _interval = 3;
    _lastTime = [[NSDate date] timeIntervalSince1970];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(timerProc:) userInfo:nil repeats:YES];
    
    [self.theLock unlock];
}

- (void)stop {

    [self.theLock lock];
    
    if (_timer) {
        [_timer invalidate];
        _timer = nil;
    }

    [self stopBrowser];
    [self stopAdvertiser];
    
    [self.session disconnect];
    
    NSLog(@"handler stopped");
    
    _isStarted = NO;
    _isConnected = NO;
    
    [self.theLock unlock];
}


- (BOOL)isStarted {
    return _isStarted;
}

- (void)getPeers:(NSMutableArray *__autoreleasing *)peersArray
{
    [self.theLock lock];
    NSMutableArray *array = [[NSMutableArray alloc] init];
    if (self.session == nil || [self.session.connectedPeers count] <= 0)
    {
        *peersArray = array;
        return;
    }
    
    for (int i = 0; i < self.session.connectedPeers.count; i++) {
        MCPeerID *peerID = [self.session.connectedPeers objectAtIndex:i];
        NSArray *keys = [self.peers allKeys];
        for (NSString *uid in keys) {
            MCPeerID *regPeerID = [self.peers objectForKey:uid];
            if ([regPeerID isEqual:peerID])
            {
                MAPeerID *maPeerID = [[MAPeerID alloc] init];
                maPeerID.peerID = regPeerID;
                maPeerID.uid = [NSString stringWithFormat:@"%@", uid];
                
                //if (![array containsObject:maPeerID])
                    [array addObject:maPeerID];
                break;
            }
        }
    }
    [self.theLock unlock];
}

- (void)setupPeerWithDisplayName:(NSString *)displayName {
    self.peerID = [[MAPeerID alloc] init];
    self.peerID.peerID = [[MCPeerID alloc] initWithDisplayName:displayName];
    self.peerID.uid = [NSString stringWithFormat:@"%@", [MAGlobalData sharedData].deviceToken];
}

- (void)setupSession {
    self.session = [[MCSession alloc] initWithPeer:self.peerID.peerID];
    self.session.delegate = self;
}


- (void)startBrowser {

    [self.theLock lock];
    
    self.browser = [[MCNearbyServiceBrowser alloc] initWithPeer:self.peerID.peerID serviceType:kServiceType];
    self.browser.delegate = self;
    
    [self.browser startBrowsingForPeers];
    
    NSLog(@"start browsing");
    
    [self.theLock unlock];
}

- (void)stopBrowser {
    [self.theLock lock];

    [self.browser stopBrowsingForPeers];
    self.browser.delegate = nil;
    self.browser = nil;
    
    NSLog(@"stop browsing");
    
    [self.theLock unlock];
}

- (void)startAdvertiser {
    
    [self.theLock lock];
    
    NSDictionary *discoveryInfo = @{kDiscoveryUidKey: [MAGlobalData sharedData].deviceToken};
    
    self.advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:self.peerID.peerID discoveryInfo:discoveryInfo serviceType:kServiceType];
    self.advertiser.delegate = self;
    [self.advertiser startAdvertisingPeer];
    
    _isAdvertising = YES;
    
    NSLog(@"start advertising");
    
    [self.theLock unlock];
}

- (void)stopAdvertiser {
    [self.theLock lock];
    
    [self.advertiser stopAdvertisingPeer];
    self.advertiser.delegate = nil;
    self.advertiser = nil;
    
    _isAdvertising = NO;
    
    _isInvited = NO;
    
    NSLog(@"stop advertising");
    
    [self.theLock unlock];
}

- (NSUInteger)numberOfConnectedPeers {
    NSUInteger count = 0;
    
    [self.theLock lock];
    
    if (self.session)
        count = [self.session.connectedPeers count];
    
    [self.theLock unlock];
    
    return count;
}

#pragma mark - Session Delegate
- (void)session:(MCSession *)session peer:(MCPeerID *)peerID didChangeState:(MCSessionState)state {
    
    
    [self.theLock lock];
    if (![session isEqual:self.session])
    {
        NSLog(@"not same session");
        [self.theLock unlock];
        return;
    }
    
    
    NSDictionary *userInfo = @{ @"peerID": peerID,
                                @"state" : @(state) };
    
    NSLog(@"didChangeState : %d, displayName : %@", (int)state, [peerID displayName]);
    
    for (NSDictionary *invitePeer in _invitingPeers) {
        //NSNumber *invitingTime = [invitePeer objectForKey:@"time"];
        MCPeerID *invitePeerID = [invitePeer objectForKey:@"peerID"];
        if ([invitePeerID isEqual:peerID])
        {
            [_invitingPeers removeObject:invitePeer];
        }
    }
    
    if (state == MCSessionStateNotConnected &&
        _advertisingPeer != nil &&
        [_advertisingPeer isEqualToString:[peerID displayName]])
    {
        [self.session disconnect];
    }
    
    
    if (self.session.connectedPeers.count <= 0)
    {
        _isConnected = NO;
        _advertisingPeer = nil;
    }
    else
    {
        _isConnected = YES;
    }

    [self.theLock unlock];
    
    [self.delegateLock lock];
    if (self.delegate)
        [self.delegate peerStateChanged:userInfo];
    [self.delegateLock unlock];

}

- (void)session:(MCSession *)session didReceiveData:(NSData *)data fromPeer:(MCPeerID *)peerID {
    
    NSLog(@"received data from : %@", [peerID displayName]);
    
    MAMessage *message = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    message.jsmessage.messageType = JSBubbleMessageTypeIncoming;
    NSMutableArray *messageArray = [self.messages objectForKey:message.senderUid];
    if (messageArray == nil)
    {
        messageArray = [[NSMutableArray alloc] init];
        [messageArray addObject:message];
        [self.messages setObject:messageArray forKey:message.senderUid];
    }
    else
        [messageArray addObject:message];
    
    [self.delegateLock lock];
    if (self.delegate)
        [self.delegate peerDataReceived:message];
    [self.delegateLock unlock];
}

- (void)session:(MCSession *)session didStartReceivingResourceWithName:(NSString *)resourceName fromPeer:(MCPeerID *)peerID withProgress:(NSProgress *)progress {
    
}

- (void)session:(MCSession *)session didFinishReceivingResourceWithName:(NSString *)resourceName fromPeer:(MCPeerID *)peerID atURL:(NSURL *)localURL withError:(NSError *)error {
    
}

- (void)session:(MCSession *)session didReceiveStream:(NSInputStream *)stream withName:(NSString *)streamName fromPeer:(MCPeerID *)peerID {
    
}


#pragma mark - Advertiser Delegate
- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didNotStartAdvertisingPeer:(NSError *)error
{
    //
}

- (void)advertiser:(MCNearbyServiceAdvertiser *)advertiser didReceiveInvitationFromPeer:(MCPeerID *)peerID withContext:(NSData *)context invitationHandler:(void (^)(BOOL, MCSession *))invitationHandler
{
    [self.theLock lock];
    
    if (context)
    {
        NSString *uid = [[NSString alloc] initWithData:context encoding:NSUTF8StringEncoding];
        if (![uid isEqualToString:@""])
            [self.peers setObject:peerID forKey:uid];
    }
    
    if (_advertisingPeer == nil && [[self.peerID.peerID displayName] caseInsensitiveCompare:[peerID displayName]] == NSOrderedAscending)
    {
        _lastInviteTime = [[NSDate date] timeIntervalSince1970];
        NSLog(@"invite accepted : %@", [peerID displayName]);
        NSMutableDictionary *invitePeer = [[NSMutableDictionary alloc] init];
        [invitePeer setObject:[NSNumber numberWithInt:_lastInviteTime] forKey:@"time"];
        [invitePeer setObject:peerID forKey:@"peerID"];

        [_invitingPeers addObject:invitePeer];
        invitationHandler(YES, self.session);
        _isInvited = YES;
    }
    else
    {
        NSLog(@"invite rejected : %@", [peerID displayName]);
        invitationHandler(NO, nil);
    }
    
    [self.theLock unlock];
}


#pragma mark - Browser Delegate
- (void)browser:(MCNearbyServiceBrowser *)browser didNotStartBrowsingForPeers:(NSError *)error
{
    //
}

- (void)browser:(MCNearbyServiceBrowser *)browser foundPeer:(MCPeerID *)peerID withDiscoveryInfo:(NSDictionary *)info
{
    [self.theLock lock];
    

    NSString *uid = [info objectForKey:kDiscoveryUidKey];
    if (uid != nil && ![uid isEqualToString:@""])
    {
        [self.peers setObject:peerID forKey:uid];
    }

    NSLog(@"found peer %@ ---, advertisingPeer %@", [peerID displayName], _advertisingPeer);
    
    //if ([[self.session connectedPeers] containsObject:peerID])
    //{
    //    NSLog(@"found peer %@, already connected", [peerID displayName]);
    //}
    //else
    {
        if (_advertisingPeer == nil)
        {
            if ([[self.peerID.peerID displayName] caseInsensitiveCompare:[peerID displayName]] == NSOrderedDescending)
            {
                
                NSLog(@"found peer %@, send invite requesting", [peerID displayName]);
                NSData *context = [self.peerID.uid dataUsingEncoding:NSUTF8StringEncoding];
                
                _lastFoundPeerTime = [[NSDate date] timeIntervalSince1970];
                [browser invitePeer:peerID toSession:self.session withContext:context timeout:kFoundPeerTimeout];
                _advertisingPeer = [NSString stringWithFormat:@"%@", [peerID displayName] ];
            }
        }
        else if ([_advertisingPeer caseInsensitiveCompare:[peerID displayName]] == NSOrderedDescending)
        {
            NSLog(@"found peer %@, send invite requesting", [peerID displayName]);
            NSData *context = [self.peerID.uid dataUsingEncoding:NSUTF8StringEncoding];
            
            _lastFoundPeerTime = [[NSDate date] timeIntervalSince1970];
            [browser invitePeer:peerID toSession:self.session withContext:context timeout:kFoundPeerTimeout];
            _advertisingPeer = [NSString stringWithFormat:@"%@", [peerID displayName] ];
        }
    }

    
    [self.theLock unlock];
}

- (void)browser:(MCNearbyServiceBrowser *)browser lostPeer:(MCPeerID *)peerID
{
    //
}

- (void)timerProc:(NSTimer *)timer
{
    [self.theLock lock];
    
    // count timeout
    int curTime = [[NSDate date] timeIntervalSince1970];
    
    for (NSMutableDictionary *invitePeer in _invitingPeers) {
        NSNumber *inviteTime = [invitePeer objectForKey:@"time"];
        int time = [inviteTime intValue];
        
        
        if (curTime - time >= kInviteTimeout)
        {
            [_invitingPeers removeObject:invitePeer];
        }
    }


    

    
    if (curTime - _lastTime >= _interval)
    {
        _lastTime = curTime;
        _interval = 1 + (arc4random() % 2);
        
        
        if (_invitingPeers.count == 0)
        {
            //[self stopAdvertiser];
            //[self startAdvertiser];
        }
        
        if (_isConnected == YES)
        {
            //
        }
        else
        {
            
            
            if (curTime - _lastFoundPeerTime > kFoundPeerTimeout)
            {
                _advertisingPeer = nil;
                [self.session disconnect];
                [self stopBrowser];
                [self startBrowser];
                _lastFoundPeerTime = curTime;
            }
            
            /*
            if (_isAdvertising == NO)
            {
                if (_isFoundPeer == NO || (_isFoundPeer == YES && curTime - _lastFoundPeerTime >= kFoundPeerTimeout))
                {
                    [self stopBrowser];
                    [self.session disconnect];
                    [self setupSession];
                    [self startAdvertiser];
                }
            }
            else
            {
                if (_isInvited == NO || (_isInvited == YES && curTime - _lastInviteTime >= kInviteTimeout))
                {
                    [self stopAdvertiser];
                    [self.session disconnect];
                    [self setupSession];
                    [self startBrowser];
                }
            }
             */
        }
    }


    [self.theLock unlock];
}

- (MAMessage *)sendMessageWithText:(NSString *)text
{
    [self.theLock lock];
    
    JSMessage *message = [[JSMessage alloc] init];
    message.text = text;
    message.sender = [self.peerID.peerID displayName];
    message.messageType = JSBubbleMessageTypeOutgoing;
    message.mediaType = JSBubbleMediaTypeText;
    message.messageStyle = JSBubbleMessageStyleFlat;
    message.timestamp = [NSDate date];
    
    MAMessage *mamessage = [[MAMessage alloc] init];
    mamessage.jsmessage = message;
    mamessage.senderUid = self.peerID.uid;
    mamessage.receiverUid = @"";
    
    
    NSMutableArray *messageArray = [self.messages objectForKey:mamessage.senderUid];
    if (messageArray == nil)
    {
        messageArray = [[NSMutableArray alloc] init];
        [messageArray addObject:mamessage];
        [self.messages setObject:messageArray forKey:mamessage.senderUid];
    }
    else
    {
        [messageArray addObject:message];
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:mamessage];
    NSError *error = nil;
    if (![self.session sendData:data
                       toPeers:self.session.connectedPeers
                      withMode:MCSessionSendDataReliable
                         error:&error]) {
        NSLog(@"[Error] %@", error);
    }
    
    [self.theLock unlock];
    
    return mamessage;
}

- (MAMessage *)sendMessageWithText:(NSString *)text peerID:(MAPeerID *)targetPeerID
{
    [self.theLock lock];
    
    JSMessage *message = [[JSMessage alloc] init];
    message.text = text;
    message.sender = [self.peerID.peerID displayName];
    message.messageType = JSBubbleMessageTypeOutgoing;
    message.mediaType = JSBubbleMediaTypeText;
    message.messageStyle = JSBubbleMessageStyleFlat;
    message.timestamp = [NSDate date];
    
    MAMessage *mamessage = [[MAMessage alloc] init];
    mamessage.jsmessage = message;
    mamessage.senderUid = self.peerID.uid;
    mamessage.receiverUid = targetPeerID.uid;
    
    
    NSMutableArray *messageArray = [self.messages objectForKey:mamessage.senderUid];
    if (messageArray == nil)
    {
        messageArray = [[NSMutableArray alloc] init];
        [messageArray addObject:mamessage];
        
        [self.messages setObject:messageArray forKey:mamessage.senderUid];
    }
    else
    {
        [messageArray addObject:message];
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:mamessage];
    NSError *error = nil;
    if (![self.session sendData:data
                        toPeers:[[NSArray alloc] initWithObjects:targetPeerID.peerID, nil]
                       withMode:MCSessionSendDataReliable
                          error:&error]) {
        NSLog(@"[Error] %@", error);
    }
    
    [self.theLock unlock];
    
    return mamessage;
}

//////////////////////////////////////////////////////////////////////
- (MAMessage *)sendMessageWithImage:(UIImage *)image
{
    [self.theLock lock];
    
    JSMessage *message = [[JSMessage alloc] init];
    message.image = image;
    message.sender = [self.peerID.peerID displayName];
    message.messageType = JSBubbleMessageTypeOutgoing;
    message.mediaType = JSBubbleMediaTypeImage;
    message.messageStyle = JSBubbleMessageStyleFlat;
    message.timestamp = [NSDate date];
    
    MAMessage *mamessage = [[MAMessage alloc] init];
    mamessage.jsmessage = message;
    mamessage.senderUid = self.peerID.uid;
    mamessage.receiverUid = @"";
    
    
    NSMutableArray *messageArray = [self.messages objectForKey:mamessage.senderUid];
    if (messageArray == nil)
    {
        messageArray = [[NSMutableArray alloc] init];
        [messageArray addObject:mamessage];
        [self.messages setObject:messageArray forKey:mamessage.senderUid];
    }
    else
    {
        [messageArray addObject:message];
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:mamessage];
    NSError *error = nil;
    if (![self.session sendData:data
                        toPeers:self.session.connectedPeers
                       withMode:MCSessionSendDataReliable
                          error:&error]) {
        NSLog(@"[Error] %@", error);
    }
    
    [self.theLock unlock];
    
    
    return mamessage;
}


//////////////////////////////////////////////////////////////////////
- (MAMessage *)sendMessageWithSpeech:(NSData *)speech
{
    [self.theLock lock];
    
    JSMessage *message = [[JSMessage alloc] init];
    message.text = @"  (((....";
    message.speech = speech;
    message.sender = [self.peerID.peerID displayName];
    message.messageType = JSBubbleMessageTypeOutgoing;
    message.mediaType = JSBubbleMediaTypeSpeech;
    message.messageStyle = JSBubbleMessageStyleFlat;
    message.timestamp = [NSDate date];
    
    MAMessage *mamessage = [[MAMessage alloc] init];
    mamessage.jsmessage = message;
    mamessage.senderUid = self.peerID.uid;
    mamessage.receiverUid = @"";
    
    
    NSMutableArray *messageArray = [self.messages objectForKey:mamessage.senderUid];
    if (messageArray == nil)
    {
        messageArray = [[NSMutableArray alloc] init];
        [messageArray addObject:mamessage];
        [self.messages setObject:messageArray forKey:mamessage.senderUid];
    }
    else
    {
        [messageArray addObject:message];
    }
    
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:mamessage];
    NSError *error = nil;
    if (![self.session sendData:data
                        toPeers:self.session.connectedPeers
                       withMode:MCSessionSendDataReliable
                          error:&error]) {
        NSLog(@"[Error] %@", error);
    }
    
    [self.theLock unlock];
    
    
    return mamessage;
}


@end
