//
//  RAReorderableLayout.swift
//  RAReorderableLayout
//
//  Created by Ryo Aoyama on 10/12/14.
//  Copyright (c) 2014 Ryo Aoyama. All rights reserved.
//

import UIKit

public enum RAReorderedLayoutEdge {
    case left
    case right
    case top
    case bottom
}


private enum RAReorderedError: Error {
    case wrongFakeView
    case notIntersectWithEdges
    case cancelByDelegate
}


@objc public protocol RAReorderableLayoutDelegate {
    @objc optional func collectionView(_ collectionView: UICollectionView, atIndexPath: IndexPath, willMoveToIndexPath toIndexPath: IndexPath)
    @objc optional func collectionView(_ collectionView: UICollectionView, atIndexPath: IndexPath, didMoveToIndexPath toIndexPath: IndexPath)
    
    @objc optional func collectionView(_ collectionView: UICollectionView,
                                       allowMoveAtIndexPath indexPath: IndexPath,
                                       pointInsideCell: CGPoint) -> Bool
    @objc optional func collectionView(_ collectionView: UICollectionView, atIndexPath: IndexPath, canMoveToIndexPath: IndexPath) -> Bool
    
    @objc optional func collectionView(_ collectionView: UICollectionView, collectionViewLayout layout: RAReorderableLayout, willBeginDraggingItemAtIndexPath indexPath: IndexPath)
    @objc optional func collectionView(_ collectionView: UICollectionView, collectionViewLayout layout: RAReorderableLayout, didBeginDraggingItemAtIndexPath indexPath: IndexPath)
    @objc optional func collectionView(_ collectionView: UICollectionView, collectionViewLayout layout: RAReorderableLayout, willEndDraggingItemToIndexPath indexPath: IndexPath)
    @objc optional func collectionView(_ collectionView: UICollectionView, collectionViewLayout layout: RAReorderableLayout, didEndDraggingItemToIndexPath indexPath: IndexPath)
    
    @objc optional func collectionView(_ collectionView: UICollectionView, canRemoveCellAtIndexPath: IndexPath) -> Bool
    @objc optional func collectionView(_ collectionView: UICollectionView, didRemoveCellAtIndexPath: IndexPath)
}

@objc public protocol RAReorderableLayoutDataSource: UICollectionViewDataSource {
    @objc optional func collectionView(_ collectionView: UICollectionView, reorderingItemAlphaInSection section: Int) -> CGFloat
    @objc optional func scrollTrigerEdgeInsetsInCollectionView(_ collectionView: UICollectionView) -> UIEdgeInsets
    @objc optional func scrollTrigerPaddingInCollectionView(_ collectionView: UICollectionView) -> UIEdgeInsets
    @objc optional func scrollSpeedValueInCollectionView(_ collectionView: UICollectionView) -> CGFloat
    @objc optional func collectionViewReorderingMinimumPressDuration(_ collectionView: UICollectionView) -> CFTimeInterval
}

open class RAReorderableLayout: UICollectionViewFlowLayout, UIGestureRecognizerDelegate {
    
    private enum direction {
        case toTop
        case toEnd
        case stay
        
        fileprivate func scrollValue(speedValue: CGFloat, percentage: CGFloat) -> CGFloat {
            var value: CGFloat = 0.0
            switch self {
            case .toTop:
                value = -speedValue
            case .toEnd:
                value = speedValue
            case .stay:
                return 0
            }
            
            let proofedPercentage: CGFloat = max(min(1.0, percentage), 0)
            return value * proofedPercentage
        }
    }
    
    fileprivate var displayLink: CADisplayLink?
    
    private lazy var longPress: UILongPressGestureRecognizer = {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(RAReorderableLayout.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.1
        longPress.delegate = self
        return longPress
    }()
    
    private(set) public lazy var panGesture: UIPanGestureRecognizer = {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(RAReorderableLayout.handlePanGesture(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
        return panGesture
    }()
    
    private var continuousScrollDirection: direction = .stay
    
    fileprivate var cellFakeView: RACellFakeView?
    
    fileprivate var panTranslation: CGPoint?
    
    fileprivate var fakeCellCenter: CGPoint?
    
    fileprivate var offsetFromTop: CGFloat {
        let contentOffset = collectionView!.contentOffset
        return scrollDirection == .vertical ? contentOffset.y : contentOffset.x
    }
    
    fileprivate var insetsTop: CGFloat {
        let contentInsets = collectionView!.contentInset
        return scrollDirection == .vertical ? contentInsets.top : contentInsets.left
    }
    
    fileprivate var insetsEnd: CGFloat {
        let contentInsets = collectionView!.contentInset
        return scrollDirection == .vertical ? contentInsets.bottom : contentInsets.right
    }
    
    fileprivate var contentLength: CGFloat {
        let contentSize = collectionView!.contentSize
        return scrollDirection == .vertical ? contentSize.height : contentSize.width
    }
    
    fileprivate var collectionViewLength: CGFloat {
        let collectionViewSize = collectionView!.bounds.size
        return scrollDirection == .vertical ? collectionViewSize.height : collectionViewSize.width
    }
    
    fileprivate var fakeCellTopEdge: CGFloat? {
        if let fakeCell = cellFakeView {
            return scrollDirection == .vertical ? fakeCell.frame.minY : fakeCell.frame.minX
        }
        return nil
    }
    
    fileprivate var fakeCellEndEdge: CGFloat? {
        if let fakeCell = cellFakeView {
            return scrollDirection == .vertical ? fakeCell.frame.maxY : fakeCell.frame.maxX
        }
        return nil
    }
    
    fileprivate var triggerInsetTop: CGFloat {
        return scrollDirection == .vertical ? trigerInsets.top : trigerInsets.left
    }
    
    fileprivate var triggerInsetEnd: CGFloat {
        return scrollDirection == .vertical ? trigerInsets.top : trigerInsets.left
    }
    
    fileprivate var triggerPaddingTop: CGFloat {
        return scrollDirection == .vertical ? trigerPadding.top : trigerPadding.left
    }
    
    fileprivate var triggerPaddingEnd: CGFloat {
        return scrollDirection == .vertical ? trigerPadding.bottom : trigerPadding.right
    }
    
    // MARK: - properties
    
    /// Scroll triggering insets
    open var trigerInsets = UIEdgeInsets.init(top: 100.0, left: 100.0, bottom: 100.0, right: 100.0)
    
    /// Scroll triggering paddings (??)
    open var trigerPadding = UIEdgeInsets.zero
    
    /// Scroll speed
    open var scrollSpeedValue: CGFloat = 10.0
    
    /// Minimum press duration for the moving start
    open var minimumPressDuration: CFTimeInterval = 0.5 {
        didSet {
            longPress.minimumPressDuration = min(minimumPressDuration, 0.1)
        }
    }
    
    /// Supported edges to start deletion action
    open var screenEdgesForDeletion = [(edge: RAReorderedLayoutEdge, insetForRemove: CGFloat)]()
    
    /// Delegation
    open weak var delegate: RAReorderableLayoutDelegate?
    
    /// Datasource for elements
    open weak var dataSource: RAReorderableLayoutDataSource? {
        set { collectionView?.dataSource = dataSource }
        get { return collectionView?.dataSource as? RAReorderableLayoutDataSource }
    }
    
    /// Generate feedback at start of moving
    open var isFeedbackAtStartEnabled = true
    
    // MARK: - lifecycle
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        configureObserver()
    }
    
    public override init() {
        super.init()
        configureObserver()
    }
    
    deinit {
        removeObserver(self, forKeyPath: "collectionView")
    }
    
    override open func prepare() {
        super.prepare()
        
        // scroll trigger insets
        if let insets = dataSource?.scrollTrigerEdgeInsetsInCollectionView?(self.collectionView!) {
            trigerInsets = insets
        }
        
        // scroll trier padding
        if let padding = dataSource?.scrollTrigerPaddingInCollectionView?(self.collectionView!) {
            trigerPadding = padding
        }
        
        // scroll speed value
        if let speed = dataSource?.scrollSpeedValueInCollectionView?(collectionView!) {
            scrollSpeedValue = speed
        }
        // duration of the long press
        if let duration = dataSource?.collectionViewReorderingMinimumPressDuration?(collectionView!) {
            minimumPressDuration = duration
        }
    }
    
    // MARK: - override
    
    override open func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attributesArray = super.layoutAttributesForElements(in: rect) else { return nil }
        
        attributesArray.filter {
            $0.representedElementCategory == .cell
            }.filter {
                ($0.indexPath == cellFakeView?.indexPath)
            }.forEach {
                // reordering cell alpha
                $0.alpha = dataSource?.collectionView?(collectionView!, reorderingItemAlphaInSection: ($0.indexPath as NSIndexPath).section) ?? 0
        }
        
        return attributesArray
    }
    
    open override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "collectionView" {
            setUpGestureRecognizers()
        }else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: - private
    
    fileprivate func configureObserver() {
        addObserver(self, forKeyPath: "collectionView", options: [], context: nil)
    }
    
    fileprivate func setUpDisplayLink() {
        guard displayLink == nil else {
            return
        }
        
        displayLink = CADisplayLink(target: self, selector: #selector(RAReorderableLayout.continuousScroll))
        displayLink!.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
    }
    
    fileprivate func invalidateDisplayLink() {
        continuousScrollDirection = .stay
        displayLink?.invalidate()
        displayLink = nil
    }
    
    // begein scroll
    fileprivate func beginScrollIfNeeded() {
        guard cellFakeView != nil,
            let fakeCellTopEdge = fakeCellTopEdge,
            let fakeCellEndEdge = fakeCellEndEdge else {
                return
        }
        
        if fakeCellTopEdge <= offsetFromTop + triggerPaddingTop + triggerInsetTop {
            continuousScrollDirection = .toTop
            setUpDisplayLink()
        } else if fakeCellEndEdge >= offsetFromTop + collectionViewLength - triggerPaddingEnd - triggerInsetEnd {
            continuousScrollDirection = .toEnd
            setUpDisplayLink()
        } else {
            invalidateDisplayLink()
        }
    }
    
    // touch to the edge
    fileprivate func tryRemoveForIntersectWithEdges() throws {
        guard let fakeView = cellFakeView,
            let indexPath = fakeView.indexPath,
            let collectionView = collectionView
            , !screenEdgesForDeletion.isEmpty && !fakeView.isMoved else {
                throw RAReorderedError.wrongFakeView
        }
        
        let fakeViewFrame = fakeView.frame
        
        for (edge, inset) in screenEdgesForDeletion {
            switch edge {
            case .left:
                if fakeViewFrame.origin.x < inset {
                    try tryToDeleteCellAtIndexPath(indexPath, edge: edge, fakeView: fakeView, collectionView: collectionView)
                    return
                }
            case .top:
                if fakeViewFrame.origin.y < inset {
                    try tryToDeleteCellAtIndexPath(indexPath, edge: edge, fakeView: fakeView, collectionView: collectionView)
                    return
                }
            case .right:
                if fakeViewFrame.maxX > collectionView.contentSize.width - inset {
                    try tryToDeleteCellAtIndexPath(indexPath, edge: edge, fakeView: fakeView, collectionView: collectionView)
                    return
                }
            case .bottom:
                if fakeViewFrame.maxY > collectionView.contentSize.height - inset {
                    try tryToDeleteCellAtIndexPath(indexPath, edge: edge, fakeView: fakeView, collectionView: collectionView)
                    return
                }
            }
        }
        
        throw RAReorderedError.notIntersectWithEdges
    }
    
    
    fileprivate func tryToDeleteCellAtIndexPath(
        _ indexPath: IndexPath,
        edge: RAReorderedLayoutEdge,
        fakeView: RACellFakeView,
        collectionView: UICollectionView
        ) throws
    {
        if let action = delegate?.collectionView(_:didRemoveCellAtIndexPath:)
            , delegate?.collectionView?(collectionView, canRemoveCellAtIndexPath: indexPath) == true
        {
            action(collectionView, indexPath)
            UIView.animate(
                withDuration: 0.3,
                animations: {
                    fakeView.alpha = 0
            },
                completion: { _ in
                    if self.cellFakeView == fakeView {
                        self.fakeCellCenter = nil
                        self.cellFakeView = nil
                        self.collectionView?.deleteItems(at: [indexPath])
                    } else {
                        self.collectionView?.reloadData()
                    }
            }
            )
        } else {
            throw RAReorderedError.cancelByDelegate
        }
    }
    
    // move item
    fileprivate func moveItemIfNeeded() {
        guard let fakeCell = cellFakeView,
            let atIndexPath = fakeCell.indexPath,
            let toIndexPath = collectionView!.indexPathForItem(at: fakeCell.center) else {
                return
        }
        
        guard atIndexPath != toIndexPath else { return }
        
        // can move item
        if let canMove = delegate?.collectionView?(collectionView!, atIndexPath: atIndexPath, canMoveToIndexPath: toIndexPath) , !canMove {
            return
        }
        
        // will move item
        delegate?.collectionView?(collectionView!, atIndexPath: atIndexPath, willMoveToIndexPath: toIndexPath)
        
        let attribute = self.layoutAttributesForItem(at: toIndexPath)!
        collectionView!.performBatchUpdates({
            fakeCell.indexPath = toIndexPath
            fakeCell.cellFrame = attribute.frame
            fakeCell.changeBoundsIfNeeded(attribute.bounds)
            
            self.collectionView!.deleteItems(at: [atIndexPath])
            self.collectionView!.insertItems(at: [toIndexPath])
            
            // did move item
            self.delegate?.collectionView?(self.collectionView!, atIndexPath: atIndexPath, didMoveToIndexPath: toIndexPath)
            fakeCell.isMoved = true
            
        }, completion:nil)
    }
    
    @objc internal func continuousScroll() {
        guard let fakeCell = cellFakeView else { return }
        
        let percentage = calcTriggerPercentage()
        var scrollRate = continuousScrollDirection.scrollValue(speedValue: self.scrollSpeedValue, percentage: percentage)
        
        let offset = offsetFromTop
        let length = collectionViewLength
        
        if contentLength + insetsTop + insetsEnd <= length {
            return
        }
        
        if offset + scrollRate <= -insetsTop {
            scrollRate = -insetsTop - offset
        } else if offset + scrollRate >= contentLength + insetsEnd - length {
            scrollRate = contentLength + insetsEnd - length - offset
        }
        
        collectionView!.performBatchUpdates({
            if self.scrollDirection == .vertical {
                self.fakeCellCenter?.y += scrollRate
                fakeCell.center.y = self.fakeCellCenter!.y + self.panTranslation!.y
                self.collectionView?.contentOffset.y += scrollRate
            }else {
                self.fakeCellCenter?.x += scrollRate
                fakeCell.center.x = self.fakeCellCenter!.x + self.panTranslation!.x
                self.collectionView?.contentOffset.x += scrollRate
            }
        }, completion: nil)
        
        moveItemIfNeeded()
    }
    
    fileprivate func calcTriggerPercentage() -> CGFloat {
        guard cellFakeView != nil else { return 0 }
        
        let offset = offsetFromTop
        let offsetEnd = offsetFromTop + collectionViewLength
        let paddingEnd = triggerPaddingEnd
        
        var percentage: CGFloat = 0
        
        if self.continuousScrollDirection == .toTop {
            if let fakeCellEdge = fakeCellTopEdge {
                percentage = 1.0 - ((fakeCellEdge - (offset + triggerPaddingTop)) / triggerInsetTop)
            }
        }else if continuousScrollDirection == .toEnd {
            if let fakeCellEdge = fakeCellEndEdge {
                percentage = 1.0 - (((insetsTop + offsetEnd - paddingEnd) - (fakeCellEdge + insetsTop)) / triggerInsetEnd)
            }
        }
        
        percentage = min(1.0, percentage)
        percentage = max(0, percentage)
        return percentage
    }
    
    // gesture recognizers
    fileprivate func setUpGestureRecognizers() {
        guard let collectionView = collectionView else { return }
        
        collectionView.gestureRecognizers?.forEach { gestureRecognizer in
            if let longPress = gestureRecognizer as? UILongPressGestureRecognizer {
                longPress.require(toFail: self.longPress)
            }
        }
        
        collectionView.addGestureRecognizer(longPress)
        collectionView.addGestureRecognizer(panGesture)
    }
    
    open func cancelDrag() {
        longPress.cancel()
        panGesture.cancel()
        
        cancelDrag(toIndexPath: nil)
    }
    
    fileprivate func cancelDrag(toIndexPath: IndexPath!) {
        guard cellFakeView != nil else { return }
        
        // will end drag item
        delegate?.collectionView?(collectionView!, collectionViewLayout: self, willEndDraggingItemToIndexPath: toIndexPath)
        
        collectionView?.scrollsToTop = true
        
        fakeCellCenter = nil
        
        invalidateDisplayLink()
        
        cellFakeView!.pushBackView {
            guard let view = self.cellFakeView else {
                return
            }
            
            view.removeFromSuperview()
            self.cellFakeView = nil
            self.invalidateLayout()
            
            // did end drag item
            self.delegate?.collectionView?(self.collectionView!, collectionViewLayout: self, didEndDraggingItemToIndexPath: toIndexPath)
        }
    }
    
    // MARK: - Recognizers
    
    private var isMoveStarted = true
    
    /// Timer to start moving
    private var startMoveTimer: Timer?
    
    // long press start gesture
    @objc internal func handleLongPress(_ longPress: UILongPressGestureRecognizer!) {
        let location = longPress.location(in: collectionView)
        var optionalIndexPath: IndexPath? = collectionView?.indexPathForItem(at: location)
        
        if let cellFakeView = cellFakeView {
            optionalIndexPath = cellFakeView.indexPath
        }
        
        guard let indexPath = optionalIndexPath else { return }
        
        switch longPress.state {
        case .began:
            let currentCell = collectionView?.cellForItem(at: indexPath)
            
            cellFakeView = RACellFakeView(cell: currentCell!)
            cellFakeView!.indexPath = indexPath
            cellFakeView!.originalCenter = currentCell?.center
            cellFakeView!.cellFrame = layoutAttributesForItem(at: indexPath)!.frame
            collectionView?.addSubview(cellFakeView!)
            
            fakeCellCenter = cellFakeView!.center
            
            invalidateLayout()
            
            cellFakeView?.pushFowardView(animationDuration: minimumPressDuration)
            
            startMoveTimer?.invalidate()
            startMoveTimer = Timer.scheduledTimer(timeInterval: minimumPressDuration,
                                                  target: self,
                                                  selector: #selector(startMoving),
                                                  userInfo: nil,
                                                  repeats: false)
        case .cancelled, .ended:
            guard isMoveStarted else {
                return
            }
            startMoveTimer?.invalidate()
            do {
                try tryRemoveForIntersectWithEdges()
            } catch {
                cancelDrag(toIndexPath: indexPath)
            }
            isMoveStarted = false
        default:
            break
        }
    }
    
    @objc private func startMoving() {
        guard let indexPath = cellFakeView?.indexPath else {
            return
        }
        
        // will begin drag item
        delegate?.collectionView?(collectionView!, collectionViewLayout: self, willBeginDraggingItemAtIndexPath: indexPath)
        
        isMoveStarted = true
        collectionView?.scrollsToTop = false
        
        // did begin drag item
        delegate?.collectionView?(collectionView!, collectionViewLayout: self, didBeginDraggingItemAtIndexPath: indexPath)
        
        if isFeedbackAtStartEnabled, #available(iOS 10.0, *) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    
    // pan gesture
    @objc func handlePanGesture(_ pan: UIPanGestureRecognizer!) {
        panTranslation = pan.translation(in: collectionView!)
        if isMoveStarted,
            let cellFakeView = cellFakeView,
            let fakeCellCenter = fakeCellCenter,
            let panTranslation = panTranslation {
            switch pan.state {
            case .changed:
                cellFakeView.center.x = fakeCellCenter.x + panTranslation.x
                cellFakeView.center.y = fakeCellCenter.y + panTranslation.y
                
                beginScrollIfNeeded()
                moveItemIfNeeded()
            case .cancelled, .ended:
                invalidateDisplayLink()
            default:
                break
            }
        }
    }
    
    // gesture recognize delegate
    open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // allow move item
        let location = gestureRecognizer.location(in: collectionView)
        guard let indexPath = collectionView?.indexPathForItem(at: location),
            let cell = collectionView?.cellForItem(at: indexPath),
            delegate?.collectionView?(collectionView!, allowMoveAtIndexPath: indexPath, pointInsideCell: cell.convert(location, from: collectionView)) == true else {
                return false
        }
        
        switch gestureRecognizer {
        case longPress:
            return !(collectionView!.panGestureRecognizer.state != .possible && collectionView!.panGestureRecognizer.state != .failed)
        case panGesture:
            return !(longPress.state == .possible || longPress.state == .failed)
        default:
            return true
        }
    }
    
    open func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        switch gestureRecognizer {
        case panGesture:
            return otherGestureRecognizer === longPress
        case collectionView?.panGestureRecognizer:
            return (longPress.state != .possible || longPress.state != .failed)
        default:
            return true
        }
    }
}

/// Private constants
private enum Constants {
    
    /// Key for add shadow animation
    static let shadowAddAnimationKey = "applyShadow"
    /// Key for remove shadow animation
    static let shadowRemoveAnimationKey = "removeShadow"
    
}

private class RACellFakeView: UIView {
    
    weak var cell: UICollectionViewCell?
    
    var cellFakeImageView: UIImageView?
    
    var cellFakeHightedView: UIImageView?
    
    fileprivate var indexPath: IndexPath?
    
    fileprivate var originalCenter: CGPoint?
    
    fileprivate var cellFrame: CGRect?
    
    fileprivate var isMoved = false
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    init(cell: UICollectionViewCell) {
        super.init(frame: cell.frame)
        
        self.cell = cell
        
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 0)
        layer.shadowOpacity = 0
        layer.shadowRadius = 5.0
        layer.shouldRasterize = false
        
        cellFakeImageView = UIImageView(frame: self.bounds)
        cellFakeImageView?.contentMode = UIView.ContentMode.scaleAspectFill
        cellFakeImageView?.autoresizingMask = [.flexibleWidth , .flexibleHeight]
        
        cellFakeHightedView = UIImageView(frame: self.bounds)
        cellFakeHightedView?.contentMode = UIView.ContentMode.scaleAspectFill
        cellFakeHightedView?.autoresizingMask = [.flexibleWidth , .flexibleHeight]
        
        cell.isHighlighted = true
        cellFakeHightedView?.image = getCellImage()
        cell.isHighlighted = false
        cellFakeImageView?.image = getCellImage()
        
        addSubview(cellFakeImageView!)
        addSubview(cellFakeHightedView!)
    }
    
    func changeBoundsIfNeeded(_ bounds: CGRect) {
        if self.bounds.equalTo(bounds) { return }
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: .beginFromCurrentState,
            animations: {
                self.bounds = bounds
        },
            completion: nil
        )
    }
    
    func pushFowardView(animationDuration: TimeInterval?) {
        if let duration = animationDuration {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: .beginFromCurrentState,
                animations: {
                    self.center = self.originalCenter!
                    self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
                    self.cellFakeHightedView!.alpha = 0;
                    let shadowAnimation = CABasicAnimation(keyPath: #keyPath(CALayer.shadowOpacity))
                    shadowAnimation.fromValue = 0
                    shadowAnimation.toValue = 0.7
                    shadowAnimation.isRemovedOnCompletion = false
                    shadowAnimation.fillMode = CAMediaTimingFillMode.forwards
                    self.layer.add(shadowAnimation, forKey: Constants.shadowAddAnimationKey)
            },
                completion: { _ in
                    self.cellFakeHightedView?.removeFromSuperview()
            })
        } else {
            self.center = self.originalCenter!
            self.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
            self.layer.shadowOpacity = 0.7
        }
    }
    
    func pushBackView(_ completion: (()->Void)?) {
        layer.removeAllAnimations()
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: .beginFromCurrentState,
            animations: {
                self.transform = CGAffineTransform.identity
                self.frame = self.cellFrame!
                let shadowAnimation = CABasicAnimation(keyPath: #keyPath(CALayer.shadowOpacity))
                shadowAnimation.fromValue = self.layer.shadowOpacity
                shadowAnimation.toValue = 0
                shadowAnimation.isRemovedOnCompletion = false
                shadowAnimation.fillMode = CAMediaTimingFillMode.forwards
                self.layer.add(shadowAnimation, forKey: Constants.shadowRemoveAnimationKey)
        },
            completion: { _ in
                completion?()
        }
        )
    }
    
    fileprivate func getCellImage() -> UIImage {
        UIGraphicsBeginImageContextWithOptions(cell!.bounds.size, false, UIScreen.main.scale * 2)
        defer { UIGraphicsEndImageContext() }
        
        cell!.drawHierarchy(in: cell!.bounds, afterScreenUpdates: true)
        return UIGraphicsGetImageFromCurrentImageContext()!
    }
}

// Convenience method
private func ~= (obj:NSObjectProtocol?, r:UIGestureRecognizer) -> Bool {
    return r.isEqual(obj)
}

extension UIGestureRecognizer {
    
    /// Отменяет действие рекогнайзера
    fileprivate func cancel() {
        guard isEnabled else {
            return
        }
        
        isEnabled = false
        isEnabled = true
    }
    
}
